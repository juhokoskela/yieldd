const {createHash} = require('node:crypto');
const {execFileSync} = require('node:child_process');
async function main() {
  const base = process.env.ACTIONS_RESULTS_URL;
  if (base !== 'http://192.168.127.1:7341/') throw Error('Expected local Results gateway');
  const token = process.env.ACTIONS_RUNTIME_TOKEN;
  if (!token) throw Error('Missing job authentication');
  execFileSync('zstd', ['--version'], {stdio:'ignore'});
  const version = createHash('sha256').update('proof-archive|zstd-without-long|1.0').digest('hex');
  const key = 'yieldd-immutable-' + process.env.GITHUB_RUN_ID;
  async function rpc(operation, fields) {
    return fetch(base+'twirp/github.actions.results.api.v1.CacheService/'+operation,{
      method:'POST',redirect:'error',signal:AbortSignal.timeout(12000),
      headers:{'Authorization':'Bearer '+token,'Content-Type':'application/json'},
      body:JSON.stringify({key,version,...fields}),
    });
  }
  let r=await rpc('GetCacheEntryDownloadURL',{restore_keys:[]});
  if (r.status!==200 || !(await r.json()).ok) throw Error('Exact cache version was not found');
  r=await rpc('CreateCacheEntry',{});
  const conflict=await r.json();
  if (r.status!==409 || conflict.code!=='already_exists') throw Error('Duplicate reservation did not return already_exists: HTTP '+r.status);
  console.log('Exact existing cache version: duplicate reservation returned HTTP 409 already_exists');
}
main().catch(e=>{console.error(e.message);process.exitCode=1})
