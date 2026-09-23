// Google Apps Script web app that lets the recorder drop files into Drive,
// and publishes the no-ads shows as a private podcast feed (?action=feed).
// Deploy as: Web app, Execute as "Me", Who has access "Anyone".
// The recorder calls ?key=...&name=...&size=...[&sub=subfolder] and gets back a
// one-time Drive upload link; each call also deletes files older than KEEP_DAYS.

const KEY = 'REPLACE_WITH_SECRET_KEY';
const FOLDER_NAME = 'The Ticket';
const KEEP_DAYS = 30;
// GitHub's own scheduler started shows hours late, so Google starts them instead.
// Paste a GitHub token here (Actions read/write on ticket-recorder only), then run
// setupSchedule once from the editor.
const GH_TOKEN = 'PASTE_GITHUB_TOKEN_HERE';

function doGet(e) {
  if (e.parameter.key !== KEY) return reply_('forbidden');
  if (e.parameter.action === 'feed') return reply_(buildFeed_());
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

// Rebuilds feed.xml (kept in the extras subfolder, same file id every time) from
// the audio files in the main folder, newest first. Episode files and the feed
// are shared "anyone with the link" so a podcast app can fetch them; returns
// the feed's address.
function buildFeed_() {
  const main = folder_();
  const eps = [];
  const files = main.getFiles();
  while (files.hasNext()) {
    const f = files.next();
    if (!/\.m4a$/i.test(f.getName())) continue;
    f.setSharing(DriveApp.Access.ANYONE_WITH_LINK, DriveApp.Permission.VIEW);
    eps.push(f);
  }
  eps.sort((a, b) => b.getDateCreated() - a.getDateCreated());
  const esc = s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  const items = eps.map(f => {
    const url = 'https://drive.usercontent.google.com/download?id=' + f.getId() + '&amp;export=download&amp;confirm=t';
    return '<item><title>' + esc(f.getName().replace(/\.m4a$/i, '')) + '</title>' +
      '<guid isPermaLink="false">' + f.getId() + '</guid>' +
      '<pubDate>' + f.getDateCreated().toUTCString() + '</pubDate>' +
      '<enclosure url="' + url + '" length="' + f.getSize() + '" type="audio/x-m4a"/></item>';
  }).join('\n');
  const xml = '<?xml version="1.0" encoding="UTF-8"?>\n' +
    '<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>\n' +
    '<title>The Ticket (no ads)</title><link>https://www.theticket.com/</link>' +
    '<description>The Musers and The Hardline, ads removed. Private feed.</description>' +
    '<language>en-us</language><itunes:block>Yes</itunes:block>\n' + items + '\n</channel></rss>';
  const extras = subfolder_(main, 'Full recordings & transcripts');
  const it = extras.getFilesByName('feed.xml');
  const feed = it.hasNext() ? it.next() : extras.createFile('feed.xml', xml, 'application/rss+xml');
  feed.setContent(xml);
  feed.setSharing(DriveApp.Access.ANYONE_WITH_LINK, DriveApp.Permission.VIEW);
  return 'https://drive.usercontent.google.com/download?id=' + feed.getId() + '&export=download&confirm=t';
}

// Weekday start times, Central. Google runs each within ~15 minutes of the time.
function setupSchedule() {
  ScriptApp.getProjectTriggers()
    .filter(t => /^start(Musers|Hardline)$/.test(t.getHandlerFunction()))
    .forEach(t => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('startMusers').timeBased().everyDays(1).atHour(5).nearMinute(15)
    .inTimezone('America/Chicago').create();
  ScriptApp.newTrigger('startHardline').timeBased().everyDays(1).atHour(14).nearMinute(15)
    .inTimezone('America/Chicago').create();
}

function startMusers() { start_('Musers'); }
function startHardline() { start_('Hardline'); }

function start_(show) {
  const day = Number(Utilities.formatDate(new Date(), 'America/Chicago', 'u'));  // 1=Mon..7=Sun
  if (day > 5) return;
  UrlFetchApp.fetch(
    'https://api.github.com/repos/smcdonnough/ticket-recorder/actions/workflows/record.yml/dispatches', {
      method: 'post',
      contentType: 'application/json',
      headers: { Authorization: 'Bearer ' + GH_TOKEN, Accept: 'application/vnd.github+json' },
      payload: JSON.stringify({ ref: 'main', inputs: { show: show } }),
    });
}

// Run once from the editor to grant Drive access before deploying.
function authorize() { folder_(); }

function reply_(text) { return ContentService.createTextOutput(text); }
