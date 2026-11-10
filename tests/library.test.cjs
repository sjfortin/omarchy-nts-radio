const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
function load(file, imports = {}) {
  const code = fs.readFileSync(path.join(__dirname, '..', file), 'utf8').replace(/^\.import .*$/gm, '');
  const context = vm.createContext({ ...imports, module: { exports: {} } });
  vm.runInContext(code, context);
  return context.module.exports;
}
const Model = load('Model.js');
const NtsApi = load('NtsApi.js', { Model });
const Library = load('Library.js', { Model, NtsApi });
const episode = id => ({ valid: true, showAlias: 'show', episodeAlias: id, name: id, audioUrl: `https://soundcloud.com/nts/${id}` });

test('old libraries migrate without losing saves or resume positions', () => {
  const lib = Library.load(JSON.stringify({ version: 1, shows: [{ alias: 'show', name: 'Show' }], episodes: [episode('a')], resume: [{ ...episode('b'), positionSec: 120, durationSec: 3600 }] }));
  assert.equal(lib.shows.length, 1); assert.equal(lib.episodes.length, 1);
  assert.equal(lib.resume[0].positionSec, 120);
  assert.equal(lib.history.length, 0); assert.equal(lib.queue.length, 0);
});
test('queue ordering and removal preserve the source and reject invalid audio', () => {
  let lib = Library.enqueue(Library.emptyLibrary(), episode('a'), false);
  lib = Library.enqueue(lib, episode('b'), true);
  assert.equal(lib.queue[0].episodeAlias, 'b');
  const moved = Library.moveQueued(lib, 0, 1);
  assert.equal(lib.queue[0].episodeAlias, 'b');
  assert.equal(moved.queue[0].episodeAlias, 'a');
  assert.equal(Library.removeQueued(moved, 1).queue.length, 1);
  assert.equal(Library.enqueue(lib, { ...episode('bad'), audioUrl: 'file:///etc/passwd' }, false), lib);
});
test('queue and history stay bounded; replay deduplicates history', () => {
  let lib = Library.emptyLibrary();
  for (let i = 0; i < 250; i++) {
    lib = Library.enqueue(lib, episode(`item-${i}`), false);
    lib = Library.notePlayed(lib, episode(`item-${i}`), i);
  }
  assert.equal(lib.queue.length, 100); assert.equal(lib.history.length, 200);
  lib = Library.notePlayed(lib, episode('item-100'), 999);
  assert.equal(lib.history[0].episodeAlias, 'item-100');
  assert.equal(lib.history.filter(x => x.episodeAlias === 'item-100').length, 1);
  assert.equal(Library.clearHistory(lib).history.length, 0);
});
test('backup roundtrip validates versions, structure, size and audio URLs', () => {
  let lib = Library.enqueue(Library.emptyLibrary(), episode('a'), false);
  lib = Library.notePlayed(lib, episode('b'), 1);
  const backup = Library.importLibrary(Library.serialize(lib));
  assert.equal(backup.queue[0].episodeAlias, 'a'); assert.equal(backup.history[0].episodeAlias, 'b');
  for (const raw of ['oops', '{}', JSON.stringify({ version: 999, shows: [], episodes: [], resume: [] }), ' '.repeat(4000001)]) assert.equal(Library.importLibrary(raw), null);
  const safe = Library.importLibrary(JSON.stringify({ version: 2, shows: [], episodes: [{ ...episode('evil'), audioUrl: 'https://evil.test/audio' }], resume: [] }));
  assert.equal(safe.episodes[0].audioUrl, '');
});

test('shared tooltip cannot interpret raw or entity-encoded markup', () => {
  const raw = Model.plainText('&lt;img src="https://example.test/tracker"&gt;');
  const tooltip = Model.tooltipText(raw + '\n&#60;b&#62;hello&#60;/b&#62;');
  assert.equal(/[<>&]/.test(tooltip), false);
  assert.ok(tooltip.includes('hello'));
});
