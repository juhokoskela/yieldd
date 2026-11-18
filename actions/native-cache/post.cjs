'use strict'

if (process.env.STATE_writable === 'true') {
  require('./index.cjs').request('save').catch(error => {
    console.error(error.message)
    process.exitCode = 1
  })
}
