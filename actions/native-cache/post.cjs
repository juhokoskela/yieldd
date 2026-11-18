'use strict'

if (process.env.STATE_writable === 'true') {
  require('./index.cjs').request('save').catch(() => {
    console.log('::warning::The runner did not confirm the native cache save request.')
  })
}
