'use strict'

const fs = require('node:fs/promises')
const path = require('node:path')

const origin = 'http://192.168.127.1:7341/'

async function request(operation) {
  if (process.env.ACTIONS_RESULTS_URL !== origin || !process.env.ACTIONS_RUNTIME_TOKEN) {
    throw new Error('The yieldd cache endpoint or job token is unavailable.')
  }
  const response = await fetch(origin + 'yieldd/native/' + operation, {
    method: 'POST',
    headers: {Authorization: 'Bearer ' + process.env.ACTIONS_RUNTIME_TOKEN},
    redirect: 'error',
    signal: AbortSignal.timeout(190_000),
  })
  if (!response.ok) throw new Error('Native cache ' + operation + ' failed (HTTP ' + response.status + ').')
  return response.json()
}

async function open() {
  let directory
  if (process.env.ACTIONS_RESULTS_URL === origin) {
    const result = await request('open')
    directory = process.platform === 'darwin' ? '/Volumes/YielddCache' : '/mnt/yieldd-cache'
    if (result.path !== directory) throw new Error('The native cache returned an unexpected mount point.')
    await fs.appendFile(process.env.GITHUB_STATE, 'opened=true\n')
  } else {
    directory = await fs.mkdtemp(path.join(process.env.RUNNER_TEMP, 'yieldd-cache-'))
    console.log('Using a temporary cache directory on this runner.')
  }
  await fs.appendFile(process.env.GITHUB_ENV, 'YIELDD_CACHE_PATH=' + directory + '\n')
  await fs.appendFile(process.env.GITHUB_OUTPUT, 'path=' + directory + '\n')
}

module.exports = {request}
if (require.main === module) open().catch(error => { console.error(error.message); process.exitCode = 1 })
