/**
 * Google Apps Script: copies the NDN dashboard tables from Supabase (Edge Function tableau-feed) into this
 * Google Sheet, one tab per table. Tableau Public connects to this Sheet and refreshes from it daily.
 *
 * Setup (once): see google_sheets/README.md.
 *   Project Settings > Script Properties:  FEED_URL = https://<project>.supabase.co/functions/v1/tableau-feed
 *                                          FEED_SECRET = the NDN_CRON_SECRET value from .env
 *   Run setup() once: creates the daily trigger (16:00-17:00 PH) and does a first refresh.
 */
const TABLES = ['account', 'video', 'songs', 'insights', 'tiktok', 'hashtags', 'scorecard'];
const TEXT_COLUMNS = ['video_id', 'song_key', 'published_at'];   // keep as text: Sheets would round long IDs

function refreshAll() {
  const props = PropertiesService.getScriptProperties();
  const url = props.getProperty('FEED_URL');
  const secret = props.getProperty('FEED_SECRET');
  if (!url || !secret) throw new Error('Set FEED_URL and FEED_SECRET in Project Settings > Script Properties');
  const book = SpreadsheetApp.getActiveSpreadsheet();
  const log = [];
  TABLES.forEach(function (t) {
    const res = UrlFetchApp.fetch(url + '?t=' + t, {headers: {'x-cron-secret': secret}, muteHttpExceptions: true});
    if (res.getResponseCode() !== 200) throw new Error(t + ': HTTP ' + res.getResponseCode() + ' ' + res.getContentText());
    const data = JSON.parse(res.getContentText());
    const values = [data.columns].concat(data.rows.map(function (r) {
      return r.map(function (v) { return v === null ? '' : v; });
    }));
    const sheet = book.getSheetByName(t) || book.insertSheet(t);
    sheet.clearContents();
    data.columns.forEach(function (c, i) {
      if (TEXT_COLUMNS.indexOf(c) >= 0) sheet.getRange(1, i + 1, values.length, 1).setNumberFormat('@');
    });
    sheet.getRange(1, 1, values.length, data.columns.length).setValues(values);
    log.push(t + ': ' + data.rows.length + ' rows');
  });
  const status = book.getSheetByName('status') || book.insertSheet('status');
  status.getRange('A1:B1').setValues([['last_refresh', new Date().toISOString()]]);
  status.getRange('A2:B2').setValues([['result', log.join(', ')]]);
  Logger.log(log.join(', '));
}

function setup() {
  ScriptApp.getProjectTriggers().forEach(function (tr) { ScriptApp.deleteTrigger(tr); });
  // Script timezone should be Asia/Manila (Project Settings). Runs after the Claude insights routine (15:00 PH).
  ScriptApp.newTrigger('refreshAll').timeBased().everyDays(1).atHour(16).create();
  refreshAll();
}
