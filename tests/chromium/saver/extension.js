// Edits and saves the file named by ZIGSAW_SAVER_FILE, as the editor's Save
// does: through the workbench and its file service, not by writing it itself.
// The result is in the file's text, which tests/chromium.sh reads from disk.
const vscode = require("vscode");

exports.activate = async () => {
  const file = process.env.ZIGSAW_SAVER_FILE;
  if (!file) return;
  const document = await vscode.workspace.openTextDocument(vscode.Uri.file(file));
  const edit = new vscode.WorkspaceEdit();
  edit.insert(document.uri, new vscode.Position(0, 0), "saved by the editor\n");
  await vscode.workspace.applyEdit(edit);
  await document.save();
};
