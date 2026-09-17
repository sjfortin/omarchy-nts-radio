const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const Search = require('../Search.js');
const context = { Model: require('../Model.js'), module: { exports: {} } };
vm.runInNewContext(fs.readFileSync(require.resolve('../NtsApi.js'), 'utf8').replace(/^\.import.*$/m, ''), context);
const Api = context.module.exports;

test('pagination counts raw rows, deduplicates displayed rows and stops on an empty page', () => {
  const row = { article_type: 'episode', title: 'Reggae', article: { path: '/shows/test/episodes/one' } };
  const parsed = Api.parseSearch(JSON.stringify({ metadata: { resultset: { count: 50 } }, results: [row, row, null] }));
  assert.equal(parsed.received, 3);
  assert.equal(Search.merge([], parsed.episodes, 'episodes').length, 1);
  const group = Search.finishGroup(Search.emptyGroup(), parsed, true);
  assert.equal(group.offset, 3);
  assert.equal(group.more, true);
  assert.equal(Search.finishGroup(group, { received: 0, total: 50 }, true).more, false);
});

test('failure keeps the same offset for retry; final page and offset limit stop loading', () => {
  const group = { ...Search.emptyGroup(), offset: 24, total: 48 };
  const failed = Search.finishGroup(group, null, false);
  assert.equal(failed.offset, 24);
  assert.equal(failed.failed, true);
  assert.equal(Search.finishGroup(failed, { received: 24, total: 48 }, true).more, false);
  assert.equal(Search.finishGroup({ ...group, offset: 4992 }, { received: 24, total: 9000 }, true).more, false);
});

test('track matches retain distinct recordings and episode destinations', () => {
  const track = { showAlias: 'host', episodeAlias: 'one', artist: 'Desmond Dekker', title: 'Israelites' };
  assert.equal(Search.merge([track], [track, { ...track, episodeAlias: 'two' }, { ...track, title: '007' }], 'tracks').length, 3);
});

test('genre spelling suggestions are optional and bounded', () => {
  assert.ok(Search.genreSuggestions('Rege').includes('Reggae'));
  assert.deepEqual(Search.genreSuggestions('reggae'), []);
  assert.deepEqual(Search.genreSuggestions('Desmond Decker'), []);
  assert.deepEqual(Search.genreSuggestions(''), []);
});

test('URLs preserve spelling, encode query syntax and separate indexes and pages', () => {
  const url = new URL(Api.searchUrl('Desmond Decker & ska', ['track'], 24, 24));
  assert.equal(url.searchParams.get('q'), 'Desmond Decker & ska');
  assert.equal(url.searchParams.get('types[]'), 'track');
  assert.equal(url.searchParams.get('offset'), '24');
  assert.equal(url.searchParams.get('version'), '2');
});
