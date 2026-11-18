'use strict'

const {test} = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const {execFileSync} = require('node:child_process')

function fixture(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'yieldd-action-'))
  t.after(() => fs.rmSync(dir, {recursive: true, force: true}))
  return {
    RUNNER_TEMP: dir,
    GITHUB_OUTPUT: path.join(dir, 'outputs'),
    GITHUB_ENV: path.join(dir, 'env'),
    GITHUB_STATE: path.join(dir, 'state'),
  }
}

test('hosted fallback supplies a private directory without using a job token', t => {
  const env = fixture(t)
  env.ACTIONS_RESULTS_URL = 'https://results-receiver.actions.githubusercontent.com/'
  execFileSync(process.execPath, [path.join(__dirname, 'index.cjs')], {env})
  const dir = fs.readFileSync(env.GITHUB_OUTPUT, 'utf8').trim().slice('path='.length)
  assert.equal(path.dirname(dir), env.RUNNER_TEMP)
  assert.equal(fs.statSync(dir).mode & 0o777, 0o700)
  assert.equal(fs.readFileSync(env.GITHUB_ENV, 'utf8'), 'YIELDD_CACHE_PATH=' + dir + '\n')
  assert.ok(!fs.existsSync(env.GITHUB_STATE))
  execFileSync(process.execPath, [path.join(__dirname, 'post.cjs')], {env})
})

test('a job with no cache grant uses fresh disk space', t => {
  const env = {...fixture(t), ACTIONS_RESULTS_URL: 'http://192.168.127.1:7341/', ACTIONS_CACHE_MODE: 'none'}
  execFileSync(process.execPath, [path.join(__dirname, 'index.cjs')], {env})
  const dir = fs.readFileSync(env.GITHUB_OUTPUT, 'utf8').trim().slice('path='.length)
  assert.equal(path.dirname(dir), env.RUNNER_TEMP)
  assert.ok(!fs.existsSync(env.GITHUB_STATE))
})

test('opt-in opens the disk and requests a save at the same endpoint', t => {
  const env = fixture(t)
  env.ACTIONS_RESULTS_URL = 'http://192.168.127.1:7341/'
  env.ACTIONS_RUNTIME_TOKEN = 'fixture-token'
  const mounted = process.platform === 'darwin' ? '/Volumes/YielddCache' : '/mnt/yieldd-cache'
  const preload = path.join(env.RUNNER_TEMP, 'fetch.cjs')
  fs.writeFileSync(preload, `
    const assert = require('node:assert/strict')
    const fs = require('node:fs/promises')
    const stat = fs.stat
    fs.stat = async file => file === ${JSON.stringify(path.dirname(mounted))} ? {dev: 1}
      : file === ${JSON.stringify(mounted)} ? {dev: 2, isDirectory: () => true} : stat(file)
    global.fetch = async (url, options) => {
      assert.equal(url, process.env.ACTIONS_RESULTS_URL + 'yieldd/native/' + process.env.EXPECTED)
      assert.equal(options.method, 'POST')
      assert.equal(options.redirect, 'error')
      assert.equal(options.headers.Authorization, 'Bearer fixture-token')
      return Response.json({path: ${JSON.stringify(mounted)}})
    }
  `)
  const run = script => execFileSync(process.execPath, ['--require', preload, path.join(__dirname, script)], {env})
  env.EXPECTED = 'open'
  run('index.cjs')
  assert.equal(fs.readFileSync(env.GITHUB_OUTPUT, 'utf8'), 'path=' + mounted + '\n')
  assert.equal(fs.readFileSync(env.GITHUB_STATE, 'utf8'), 'opened=true\n')
  env.EXPECTED = 'save'
  env.STATE_opened = 'true'
  run('post.cjs')
})
