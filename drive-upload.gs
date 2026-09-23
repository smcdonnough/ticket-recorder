// Google Apps Script web app that lets the recorder drop files into Drive.
// Deploy as: Web app, Execute as "Me", Who has access "Anyone".
// The recorder calls ?key=...&name=...&size=...[&sub=subfolder] and gets back a
// one-time Drive upload link; each call also deletes files older than KEEP_DAYS.

const KEY = 'REPLACE_WITH_SECRET_KEY';
const FOLDER_NAME = 'The Ticket';
const KEEP_DAYS = 30;

function doGet(e) {
  if (e.parameter.key !== KEY) return reply_('forbidden');
  const main = folder_();
  const folder = e.parameter.sub ? subfolder_(main, e.parameter.sub) : main;
  cleanup_(main);
  if (folder !== main) cleanup_(folder);
  const res = UrlFetchApp.fetch(
    'https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable', {
      method: 'post',
      contentType: 'application/json; charset=UTF-8',
      headers: {
        Authorization: 'Bearer ' + ScriptApp.getOAuthToken(),
        'X-Upload-Content-Type': 'audio/mp4',
        'X-Upload-Content-Length': String(e.parameter.size || ''),
      },
      payload: JSON.stringify({ name: e.parameter.name, parents: [folder.getId()] }),
      muteHttpExceptions: true,
    });
  const h = res.getHeaders();
  return reply_(h.Location || h.location || ('error ' + res.getResponseCode() + ' ' + res.getContentText()));
}

function folder_() {
  const it = DriveApp.getFoldersByName(FOLDER_NAME);
  return it.hasNext() ? it.next() : DriveApp.createFolder(FOLDER_NAME);
}

function subfolder_(parent, name) {
  const it = parent.getFoldersByName(name);
  return it.hasNext() ? it.next() : parent.createFolder(name);
}

function cleanup_(folder) {
  const cutoff = Date.now() - KEEP_DAYS * 86400000;
  const files = folder.getFiles();
  while (files.hasNext()) {
    const f = files.next();
    if (f.getDateCreated().getTime() < cutoff) f.setTrashed(true);
  }
}

// Run once from the editor to grant Drive access before deploying.
function authorize() { folder_(); }

function reply_(text) { return ContentService.createTextOutput(text); }
