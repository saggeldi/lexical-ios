/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import Lexical
import UIKit

enum MergeAction {
  case historyMerge
  case historyPush
  case discardHistoryCandidate
}

enum ChangeType {
  case other
  case composingCharacter
  case insertCharacterAfterSelection
  case insertCharacterBeforeSelection
  case deleteCharacterBeforeSelection
  case deleteCharacterAfterSelection
}

public class EditorHistory {
  weak var editor: Editor?
  var externalHistoryState: HistoryState?
  var delay: Int
  var prevChangeTime: Double
  var prevChangeType: ChangeType
  private var isApplyingChange = false
  private var isUndoingOrRedoing = false
  internal var isPaused = false
  private var lastTextContent: String = ""
  private var restoringState: EditorState?  // Track state being restored during undo/redo

  public init(editor: Editor, externalHistoryState: HistoryState, delay: Int = 500) {
    self.editor = editor
    self.externalHistoryState = externalHistoryState
    self.delay = delay  // delay in milliseconds
    self.prevChangeTime = 0
    self.prevChangeType = .other
  }

  public func applyChange(
    editorState: EditorState,
    prevEditorState: EditorState,
    dirtyNodes: DirtyNodeMap
  ) {
    // Skip if we're in the middle of an undo/redo operation or recording is paused
    // This prevents the undo/redo state restoration from being recorded as a new change
    // isPaused is used during operations like importMarkdown that rebuild the tree
    guard !isUndoingOrRedoing && !isPaused else { return }

    // Prevent re-entrancy
    guard !isApplyingChange else { return }
    isApplyingChange = true
    defer { isApplyingChange = false }

    guard let editor else {
      return
    }

    let historyState: HistoryState = externalHistoryState ?? createEmptyHistoryState()
    let currentEditorState = historyState.current == nil ? nil : historyState.current?.editorState

    if historyState.current != nil && editorState == currentEditorState {
      return
    }

    // Get current text content for tracking
    var currentTextContent = ""
    do {
      try editorState.read {
        if let root = getRoot() {
          currentTextContent = root.getTextContent()
        }
      }
    } catch {}

    // Check if this is a meaningful change (content or formatting)
    // We already know editorState != currentEditorState (checked above)
    // So the state HAS changed - could be selection, content, or formatting

    // Get previous text content from current history entry for comparison
    var previousTextContent = ""
    if let currentEntry = historyState.current {
      do {
        try currentEntry.editorState.read {
          if let root = getRoot() {
            previousTextContent = root.getTextContent()
          }
        }
      } catch {}
    }

    // Detect if content changed (text is different)
    let hasTextChange = currentTextContent != previousTextContent

    // If text is the same but state is different, it could be:
    // 1. Selection-only change - we don't want to track
    // 2. Formatting change (bold, italic, etc.) - we DO want to track
    //
    // We distinguish by comparing node maps directly. If only the selection
    // changed, the node maps will be identical. If formatting changed,
    // at least one node will differ (different format attributes).
    // Note: dirtyNodes from update listeners is always empty (captured before
    // the update closure runs in beginUpdate), so we can't use it here.
    let hasContentChange: Bool
    if hasTextChange {
      hasContentChange = true
    } else if let currentEntry = historyState.current {
      // Compare node maps to detect formatting/structural changes
      let currentNodeMap = editorState.getNodeMap()
      let previousNodeMap = currentEntry.editorState.getNodeMap()
      if currentNodeMap.count != previousNodeMap.count {
        hasContentChange = true
      } else {
        var nodesMatch = true
        for (key, node) in currentNodeMap {
          if previousNodeMap[key] != node {
            nodesMatch = false
            break
          }
        }
        hasContentChange = !nodesMatch
      }
    } else {
      hasContentChange = true
    }

    // Update lastTextContent for future comparisons
    lastTextContent = currentTextContent

    // If only selection changed (no content/formatting change), update the current
    // entry's selection but don't create a new history entry
    if !hasContentChange {
      if historyState.current != nil {
        historyState.current?.undoSelection = editorState.selection?.clone() as? RangeSelection
      }
      return
    }

    // Track if this is the first change (current was nil)
    let isFirstChange = historyState.current == nil

    if isFirstChange {
      // First change - just set current to the NEW state, don't push anything to undo stack
      // This prevents the initial empty state from being undoable
      historyState.current = HistoryStateEntry(
        editor: editor,
        editorState: editorState,
        undoSelection: editorState.selection?.clone() as? RangeSelection)
      externalHistoryState = historyState
      return
    }

    do {
      let mergeAction = try getMergeAction(
        prevEditorState: prevEditorState,
        nextEditorState: editorState,
        currentHistoryEntry: historyState.current,
        dirtyNodes: dirtyNodes,
        hasContentChange: hasContentChange)

      if mergeAction == .historyPush {
        if !historyState.redoStack.isEmpty {
          historyState.redoStack = []
          editor.dispatchCommand(type: .canRedo, payload: false)
        }

        // Push current state to undo stack (this is the state BEFORE the change)
        if let current = historyState.current, let editor = current.editor {
          historyState.undoStack.append(
            HistoryStateEntry(
              editor: editor,
              editorState: current.editorState,
              undoSelection: current.undoSelection))
        }

        editor.dispatchCommand(type: .canUndo, payload: true)
      } else if mergeAction == .discardHistoryCandidate {
        return
      }

      // Update current to the new state
      historyState.current = HistoryStateEntry(
        editor: editor,
        editorState: editorState,
        undoSelection: editorState.selection?.clone() as? RangeSelection)

      externalHistoryState = historyState
    } catch {
      print("Failed to get mergeAction: \(error.localizedDescription)")
    }
  }

  func undo() {
    guard let externalHistoryState,
      externalHistoryState.undoStack.count != 0,
      let editor
    else { return }

    // Prevent applyChange from recording this as a new change
    // Keep the flag true until after setEditorState completes
    isUndoingOrRedoing = true

    var historyStateEntry = externalHistoryState.undoStack.removeLast()
    if let current = externalHistoryState.current {
      externalHistoryState.redoStack.append(current)
    }

    externalHistoryState.current = historyStateEntry

    // Update lastTextContent to match the restored state
    do {
      try historyStateEntry.editorState.read {
        if let root = getRoot() {
          lastTextContent = root.getTextContent()
        }
      }
    } catch {}

    do {
      // Always restore the editor state, even if undoSelection is nil.
      // Previous code skipped setEditorState when undoSelection was nil,
      // causing undo to silently fail (stacks modified but editor unchanged).
      let stateToRestore: EditorState
      if let undoSelection = historyStateEntry.undoSelection {
        stateToRestore = historyStateEntry.editorState.clone(selection: undoSelection)
      } else {
        stateToRestore = historyStateEntry.editorState
      }
      try editor.setEditorState(stateToRestore)
      editor.dispatchCommand(type: .updatePlaceholderVisibility)
    } catch {
      editor.log(.other, .warning, "undo: Failed to setEditorState: \(error.localizedDescription)")
    }

    // Reset flag AFTER setEditorState completes
    isUndoingOrRedoing = false

    // Always dispatch both canUndo and canRedo to ensure UI stays in sync
    editor.dispatchCommand(type: .canUndo, payload: externalHistoryState.undoStack.count > 0)
    editor.dispatchCommand(type: .canRedo, payload: true)

    self.externalHistoryState = externalHistoryState
  }

  func redo() {
    guard let externalHistoryState,
      externalHistoryState.redoStack.count != 0,
      let editor
    else { return }

    // Prevent applyChange from recording this as a new change
    // Keep the flag true until after setEditorState completes
    isUndoingOrRedoing = true

    if let current = externalHistoryState.current {
      externalHistoryState.undoStack.append(current)
    }

    let historyStateEntry = externalHistoryState.redoStack.removeLast()
    externalHistoryState.current = historyStateEntry

    // Update lastTextContent to match the restored state
    do {
      try historyStateEntry.editorState.read {
        if let root = getRoot() {
          lastTextContent = root.getTextContent()
        }
      }
    } catch {}

    do {
      // Always restore the editor state, even if undoSelection is nil
      let stateToRestore: EditorState
      if let undoSelection = historyStateEntry.undoSelection {
        stateToRestore = historyStateEntry.editorState.clone(selection: undoSelection)
      } else {
        stateToRestore = historyStateEntry.editorState
      }
      try editor.setEditorState(stateToRestore)
      editor.dispatchCommand(type: .updatePlaceholderVisibility)
    } catch {
      editor.log(.other, .warning, "redo: Failed to setEditorState: \(error.localizedDescription)")
    }

    // Reset flag AFTER setEditorState completes
    isUndoingOrRedoing = false

    // Always dispatch both canUndo and canRedo to ensure UI stays in sync
    editor.dispatchCommand(type: .canUndo, payload: true)
    editor.dispatchCommand(type: .canRedo, payload: externalHistoryState.redoStack.count > 0)

    self.externalHistoryState = externalHistoryState
  }

  public func applyCommand(type: CommandType) {
    if type == .redo {
      redo()
    } else if type == .undo {
      undo()
    } else if type == .clearEditor {
      guard let externalHistoryState else { return }

      clearHistory(historyState: externalHistoryState)
    }
  }

  func getMergeAction(
    prevEditorState: EditorState?,
    nextEditorState: EditorState,
    currentHistoryEntry: HistoryStateEntry?,
    dirtyNodes: DirtyNodeMap,
    hasContentChange: Bool = true
  ) throws -> MergeAction {
    guard let editor else {
      return .discardHistoryCandidate
    }
    let changeTime = Date().timeIntervalSince1970

    if prevChangeTime == 0 {
      prevChangeTime = Date().timeIntervalSince1970
    }

    let changeType = try getChangeType(
      prevEditorState: prevEditorState,
      nextEditorState: nextEditorState,
      dirtyLeavesSet: dirtyNodes,
      isComposing: editor.isComposing())

    let isSameEditor = currentHistoryEntry == nil || currentHistoryEntry?.editor == self.editor

    // If content actually changed, we should track it
    if hasContentChange {
      // Convert delay from milliseconds to seconds for comparison
      let delayInSeconds = Double(self.delay) / 1000.0

      // Merge if: within the delay window (e.g., rapid typing within 500ms)
      // This groups rapid keystrokes into a single undo action
      if changeTime < prevChangeTime + delayInSeconds && isSameEditor {
        prevChangeTime = changeTime
        prevChangeType = changeType
        return .historyMerge
      }

      // Otherwise, push a new history entry
      prevChangeTime = changeTime
      prevChangeType = changeType
      return .historyPush
    }

    // No content change - discard
    return .discardHistoryCandidate
  }
}

public struct HistoryStateEntry {
  weak var editor: Editor?
  var editorState: EditorState
  var undoSelection: RangeSelection?

  public init(editor: Editor?, editorState: EditorState, undoSelection: RangeSelection?) {
    self.editor = editor
    self.editorState = editorState
    self.undoSelection = undoSelection
  }
}

public class HistoryState {
  var current: HistoryStateEntry?
  var redoStack: [HistoryStateEntry] = []
  var undoStack: [HistoryStateEntry] = []

  public init(current: HistoryStateEntry?, redoStack: [HistoryStateEntry], undoStack: [HistoryStateEntry]) {
    self.current = current
    self.redoStack = redoStack
    self.undoStack = undoStack
  }

  public func undoStackCount() -> Int {
    return undoStack.count
  }

  public func redoStackCount() -> Int {
    return redoStack.count
  }
}

func getDirtyNodes(
  editorState: EditorState,
  dirtyLeavesSet: DirtyNodeMap
) -> [Node] {
  let dirtyLeaves = dirtyLeavesSet
  let nodeMap = editorState.getNodeMap()
  var nodes: [Node] = []

  for (dirtyLeafKey, cause) in dirtyLeaves {
    if cause == .editorInitiated {
      continue
    }

    if let dirtyLeaf = nodeMap[dirtyLeafKey] {
      if dirtyLeaf is TextNode {
        nodes.append(dirtyLeaf)
      }
    }

    if let dirtyElement = nodeMap[dirtyLeafKey] {
      if dirtyElement is ElementNode && !isRootNode(node: dirtyElement) {
        nodes.append(dirtyElement)
      }
    }
  }
  return nodes
}

func getChangeType(
  prevEditorState: EditorState?,
  nextEditorState: EditorState,
  dirtyLeavesSet: DirtyNodeMap,
  isComposing: Bool
) throws -> ChangeType {
  if prevEditorState == nil || dirtyLeavesSet.count == 0 {
    return .other
  }

  guard let prevEditorState else { return .other }

  if isComposing {
    return .composingCharacter
  }

  guard let nextSelection = nextEditorState.selection,
    let prevSelection = prevEditorState.selection
  else {
    throw LexicalError.internal("Failed to find selection")
  }

  guard let nextSelection = nextSelection as? RangeSelection,
    let prevSelection = prevSelection as? RangeSelection
  else {
    return .other
  }

  if !prevSelection.isCollapsed() || !nextSelection.isCollapsed() {
    return .other
  }

  let dirtyNodes = getDirtyNodes(editorState: nextEditorState, dirtyLeavesSet: dirtyLeavesSet)
  if dirtyNodes.count == 0 {
    return .other
  }

  // Catching the case when inserting new text node into an element (e.g. first char in paragraph/list),
  // or after existing node.
  if dirtyNodes.count > 1 {
    let nextNodeMap = nextEditorState.getNodeMap()

    let prevAnchorNode = nextNodeMap[prevSelection.anchor.key]

    if let nextAnchorNode = nextNodeMap[nextSelection.anchor.key] as? TextNode,
      prevAnchorNode != nil,
      !prevEditorState.getNodeMap().keys.contains(nextAnchorNode.key),
      nextAnchorNode.getTextPartSize() == 1,
      nextSelection.anchor.offset == 1
    {
      return .insertCharacterAfterSelection
    }
    return .other
  }

  let nextDirtyNode = dirtyNodes[0]
  let prevDirtyNode = prevEditorState.getNodeMap()[nextDirtyNode.key]

  if !isTextNode(prevDirtyNode) || !isTextNode(nextDirtyNode) {
    return .other
  }

  guard
    let prevDirtyNode = prevDirtyNode as? TextNode,
    let nextDirtyNode = nextDirtyNode as? TextNode
  else {
    throw LexicalError.internal("prev/nextDirtyNode is not TextNode")
  }

  if prevDirtyNode.getMode_dangerousPropertyAccess() != nextDirtyNode.getMode_dangerousPropertyAccess() {
    return .other
  }

  // we don't want the text from latest node
  let prevText = prevDirtyNode.getText_dangerousPropertyAccess()
  let nextText = nextDirtyNode.getText_dangerousPropertyAccess()
  if prevText == nextText {
    return .other
  }

  let nextAnchor = nextSelection.anchor
  let prevAnchor = prevSelection.anchor
  if nextAnchor.key != prevAnchor.key || nextAnchor.type != .text {
    return .other
  }

  let nextAnchorOffset = nextAnchor.offset
  let prevAnchorOffset = prevAnchor.offset
  let textDiff = nextText.lengthAsNSString() - prevText.lengthAsNSString()
  if textDiff == 1 && prevAnchorOffset == nextAnchorOffset - 1 {
    return .insertCharacterAfterSelection
  }
  if textDiff == -1 && prevAnchorOffset == nextAnchorOffset + 1 {
    return .deleteCharacterBeforeSelection
  }
  if textDiff == -1 && prevAnchorOffset == nextAnchorOffset {
    return .deleteCharacterAfterSelection
  }
  return .other
}

public func createEmptyHistoryState() -> HistoryState {
  HistoryState(current: nil, redoStack: [], undoStack: [])
}

func clearHistory(historyState: HistoryState) {
  historyState.undoStack.removeAll()
  historyState.redoStack.removeAll()
  historyState.current = nil
}
