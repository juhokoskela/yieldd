const { spawnSync } = require('node:child_process')
const path = require('node:path')
const run = spawnSync('python3', [path.join(__dirname, 'measure.py'), process.execPath], {stdio: 'inherit'})
process.exitCode = run.status ?? 1
