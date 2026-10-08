const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const { mkdtemp, mkdir, writeFile, readFile, stat, rm, chmod, symlink } = require('node:fs/promises');
const { createHash } = require('node:crypto');
const { tmpdir } = require('node:os');
const { join } = require('node:path');
const { createInterface } = require('node:readline');
const { test } = require('node:test');
const { validateConfiguration, runnerEnvironment, runProcess, runListener, verifyArchive, removePrivateDirectory } = require('./index.cjs');

test('cleanup removes read-only module caches without following symlinks', async t => {
    const fixture = await mkdtemp(join(tmpdir(), 'yieldd-cleanup-test-'));
    t.after(() => removePrivateDirectory(fixture));
    const directory = join(fixture, 'bootstrap');
    const cache = join(directory, 'home/go/pkg/mod/example@v1');
    const outside = join(fixture, 'outside');
    await mkdir(cache, { recursive: true });
    await mkdir(outside);
    await writeFile(join(cache, 'LICENSE'), 'read-only module', { mode: 0o444 });
    await writeFile(join(outside, 'sentinel'), 'untouched');
    await symlink(outside, join(cache, 'outside'));
    await chmod(cache, 0o555);
    await chmod(outside, 0o555);
    await removePrivateDirectory(directory);
    await assert.rejects(stat(directory), { code: 'ENOENT' });
    assert.equal(await readFile(join(outside, 'sentinel'), 'utf8'), 'untouched');
    assert.equal((await stat(outside)).mode & 0o777, 0o555);
    await removePrivateDirectory(directory); // Lost cleanup responses are safe to retry.
});

const name = 'yieldd-bootstrap-test';
function encodeSettings(settings) {
    return Buffer.from(JSON.stringify({
        '.runner': Buffer.from(JSON.stringify(settings)).toString('base64'),
        '.credentials': Buffer.from('{}').toString('base64'),
    })).toString('base64');
}

test('accepts upstream JIT settings while enforcing runner identity and isolation', () => {
    // Sanitized decoded .runner from https://github.com/actions/actions-runner-controller/discussions/3289.
    const settings = require('./fixtures/jit-runner-settings.json');
    validateConfiguration(encodeSettings(settings), name);
    for (const ephemeral of [true, 'True', 'true', 'TRUE', ' True ']) {
        validateConfiguration(encodeSettings({ ...settings, Ephemeral: ephemeral }), name);
    }
    for (const changed of [
        { AgentName: 'other' }, { WorkFolder: '/tmp/shared' },
        ...[false, 'False', 'false', '', null, 'yes'].map(Ephemeral => ({ Ephemeral })),
        { agentName: 'other' }, { ephemeral: false }, { workFolder: '/tmp/shared' },
    ]) {
        assert.throws(() => validateConfiguration(encodeSettings({ ...settings, ...changed }), name), /JIT configuration/);
    }
});

function configuration(settings = {}, files = {}) {
    return Buffer.from(JSON.stringify({
        '.runner': Buffer.from(JSON.stringify({
            agentName: name, ephemeral: true, workFolder: '_work', ...settings,
        })).toString('base64'), '.credentials': Buffer.from('{}').toString('base64'), ...files,
    })).toString('base64');
}

test('accepts only the expected ephemeral runner in a private work directory', () => {
    validateConfiguration(configuration(), name);
    for (const settings of [{ agentName: 'other' }, { ephemeral: false }, { workFolder: '/tmp/shared' }]) {
        assert.throws(() => validateConfiguration(configuration(settings), name), /JIT configuration/);
    }
    for (const secret of [undefined, '', 'not-config', configuration({}, { '../escape': 'AA==' })]) {
        assert.throws(() => validateConfiguration(secret, name), /JIT configuration/);
    }
    assert.throws(() => validateConfiguration(configuration(), `${name}\n`), /runner-name/);
});

test('child environment is an allowlist, not a copy of bootstrap credentials or contexts', () => {
    const env = runnerEnvironment('/private/home', '/private/tmp');
    assert.deepEqual(Object.keys(env).sort(), ['HOME', 'LANG', 'PATH', 'TEMP', 'TMP', 'TMPDIR']);
    assert.equal(env.HOME, '/private/home');
    assert.equal(env.TMPDIR, '/private/tmp');
});

test('JIT accepts only the expected files with canonical nonempty base64 contents', () => {
    validateConfiguration(configuration({}, { '.credentials_rsaparams': 'e30=' }), name);
    for (const key of ['.env', '.path', '.runner_migrated', '../outside']) {
        assert.throws(() => validateConfiguration(configuration({}, { [key]: 'e30=' }), name), /JIT configuration/);
    }
    for (const value of [undefined, '', 'not-base64', 'e30=!']) {
        assert.throws(() => validateConfiguration(configuration({}, { '.credentials': value }), name), /JIT configuration/);
    }
});

test('archive contents must match the pinned checksum', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'yieldd-bootstrap-test-'));
    try {
        const path = join(directory, 'archive');
        await writeFile(path, 'runner archive');
        await verifyArchive(path, createHash('sha256').update('runner archive').digest('hex'));
        await assert.rejects(verifyArchive(path, '0'.repeat(64)), /checksum mismatch/);
    } finally { await rm(directory, { recursive: true, force: true }); }
});

test('supervisor preserves process success and failure without exposing arguments', async () => {
    const options = { env: runnerEnvironment('/tmp', '/tmp'), signal: new AbortController().signal };
    await runProcess(process.execPath, ['-e', `
        const assert = require('node:assert/strict');
        for (const key of ['GITHUB_OUTPUT', 'GITHUB_ENV', 'GITHUB_RUN_ID', 'GITHUB_TOKEN', 'INPUT_JIT-CONFIG']) {
            assert.equal(process.env[key], undefined);
        }
    `], options);
    await assert.rejects(runProcess(process.execPath, ['-e', 'process.exit(7)'], options), /status 7/);
    await assert.rejects(runProcess('/nonexistent-yieldd-test', ['secret'], options), /Failed to launch/);
});

test('an already cancelled request never launches a process', () => {
    const controller = new AbortController();
    const reason = new Error('cancelled');
    controller.abort(reason);
    assert.throws(() => runProcess('/nonexistent-yieldd-test', [], {
        env: {}, signal: controller.signal,
    }), error => error === reason);
});

async function fakeListener(t, statuses) {
    const runner = await mkdtemp(join(tmpdir(), 'yieldd-bootstrap-test-'));
    t.after(() => rm(runner, { recursive: true, force: true }));
    await mkdir(join(runner, 'bin'));
    await writeFile(join(runner, 'bin/Runner.Listener'), `#!${process.execPath}
        const fs = require('node:fs');
        const assert = require('node:assert/strict');
        assert.equal(process.argv[2], 'run');
        assert.equal(process.env.ACTIONS_RUNNER_INPUT_JITCONFIG, 'test-only-config');
        const previous = fs.existsSync('attempts') ? fs.readFileSync('attempts', 'utf8') : '';
        const attempts = previous ? JSON.parse(previous) : [];
        attempts.push(Date.now());
        fs.writeFileSync('attempts', JSON.stringify(attempts));
        process.exit(${JSON.stringify(statuses)}[attempts.length - 1] ?? 7);
    `, { mode: 0o700 });
    return {
        runner,
        options: { cwd: runner, env: { ACTIONS_RUNNER_INPUT_JITCONFIG: 'test-only-config' } },
        attempts: async () => JSON.parse(await readFile(join(runner, 'attempts'), 'utf8')),
    };
}

test('listener retries status 2 after five seconds using the same runner directory', async t => {
    const { runner, options, attempts } = await fakeListener(t, [2, 0]);
    await runListener(runner, { ...options, signal: AbortSignal.timeout(15000) });
    const started = await attempts();
    assert.equal(started.length, 2);
    assert.ok(started[1] - started[0] >= 5000);
});

test('listener terminal failures do not retry', async t => {
    for (const code of [1, 5, 7]) {
        const { runner, options, attempts } = await fakeListener(t, [code, 0]);
        await assert.rejects(runListener(runner, {
            ...options, signal: AbortSignal.timeout(15000),
        }), new RegExp(`status ${code}`));
        assert.equal((await attempts()).length, 1);
    }
});

test('cancellation during listener retry delay preserves its reason and prevents restart', async t => {
    const { runner, options, attempts } = await fakeListener(t, [2, 0]);
    const controller = new AbortController();
    const reason = new Error('bootstrap deadline reached');
    t.mock.method(console, 'log', message => {
        if (message === 'Runner listener exited with status 2; retrying in five seconds.') {
            setImmediate(() => controller.abort(reason));
        }
    });
    const deadline = setTimeout(() => controller.abort(new Error('Retry was not reported')), 10000);
    try {
        await assert.rejects(runListener(runner, { ...options, signal: controller.signal }), error => error === reason);
        assert.equal((await attempts()).length, 1);
    } finally { clearTimeout(deadline); }
});

test('listener retries do not reset the pickup deadline', { timeout: 10000 }, async t => {
    const { runner, options, attempts } = await fakeListener(t, [2, 0]);
    const controller = new AbortController();
    t.mock.timers.enable({ apis: ['setTimeout'] });
    t.mock.method(console, 'log', message => {
        if (message === 'Runner listener exited with status 2; retrying in five seconds.') {
            t.mock.timers.tick(5 * 60 * 1000);
        }
    });
    try {
        await assert.rejects(runListener(runner, { ...options, signal: controller.signal }),
            /No job start was observed within five minutes/u);
        assert.equal((await attempts()).length, 1);
    } finally {
        controller.abort();
    }
});

for (const mode of ['idle', 'started', 'marker-removed', 'home-recreated']) {
    const started = mode !== 'idle';
    test(started ? `picked-up job survives an hour and remains cancellable: ${mode}` : 'idle listener stops after five minutes without pickup',
        { timeout: 10000 }, async t => {
        const runner = await mkdtemp(join(tmpdir(), 'yieldd-bootstrap-test-'));
        const controller = new AbortController();
        const reason = new Error('cancelled by test');
        const ready = join(runner, 'ready');
        const home = join(runner, 'home');
        let running;
        try {
            await mkdir(join(runner, 'bin'));
            await mkdir(home);
            await writeFile(join(runner, 'bin/Runner.Listener'), `#!${process.execPath}
                const fs = require('node:fs');
                process.on('SIGINT', () => process.exit(0));
                if (${started}) require('node:child_process').execFileSync(process.env.ACTIONS_RUNNER_HOOK_JOB_STARTED);
                if (${mode === 'marker-removed'}) fs.rmSync(${JSON.stringify(join(home, 'job-started'))}, { force: true });
                if (${mode === 'home-recreated'}) {
                    fs.rmSync(${JSON.stringify(home)}, { recursive: true });
                    fs.mkdirSync(${JSON.stringify(home)});
                }
                fs.writeFileSync('ready', String(process.pid));
                setInterval(() => {}, 1000);
            `, { mode: 0o700 });
            t.mock.timers.enable({ apis: ['setTimeout'] });
            running = runListener(runner, {
                cwd: runner,
                env: { HOME: home },
                signal: controller.signal,
            });
            const pid = await new Promise((resolve, reject) => {
                const { watch } = require('node:fs');
                const finish = (error, value) => {
                    watcher.close();
                    error ? reject(error) : resolve(value);
                };
                const check = () => readFile(ready, 'utf8').then(value => {
                    if (/^[0-9]+$/u.test(value) && Number(value) > 1) finish(null, Number(value));
                }, () => {});
                const watcher = watch(runner, check);
                watcher.once('error', finish);
                check();
                running.then(() => finish(new Error('Listener exited before readiness')), finish);
            });
            const hook = await readFile(join(runner, 'yieldd-job-started.sh'), 'utf8');
            const url = hook.match(/http:\/\/127\.0\.0\.1:[0-9]+\/[a-f0-9]+/u)[0];
            assert.equal((await fetch(url + '/invalid', { method: 'POST' })).status, 404);
            assert.equal((await fetch(url)).status, 404);
            t.mock.timers.tick(5 * 60 * 1000 - 1);
            assert.doesNotThrow(() => process.kill(pid, 0));
            t.mock.timers.tick(1);
            if (started) {
                t.mock.timers.tick(60 * 60 * 1000);
                assert.doesNotThrow(() => process.kill(pid, 0));
                controller.abort(reason);
                await assert.rejects(running, error => error === reason);
            } else {
                await assert.rejects(running, /No job start was observed within five minutes/u);
            }
            assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
            await assert.rejects(fetch(url, { method: 'POST', signal: AbortSignal.timeout(1000) }), /fetch failed/u);
        } finally {
            controller.abort(reason);
            // Restore real timers so an unresponsive fixture still receives escalation.
            t.mock.timers.tick(5000);
            t.mock.timers.reset();
            await running?.catch(() => {});
            await rm(runner, { recursive: true, force: true });
        }
    });
}

test('bootstrap workflow leaves execution limits to GitHub', async () => {
    const workflow = await readFile(join(__dirname, '../../workflows/runner-bootstrap.yml'), 'utf8');
    assert.doesNotMatch(workflow, /timeout-minutes:/u);
});

test('manual smoke routing matches its unique JIT label instead of the shared scale-set label', async () => {
    const workflow = await readFile(join(__dirname, '../../workflows/runner-bootstrap-test.yml'), 'utf8');
    const guide = await readFile(join(__dirname, '../../../Docs/runner-bootstrap-prototype.md'), 'utf8');
    assert.match(workflow, /^\s+runs-on: \$\{\{ inputs\.runner-name \}\}$/mu);
    assert.ok(guide.includes('-f "labels[]=$runner_name"'));
    assert.doesNotMatch(guide, /-f ['"]labels\[\]=yieldd['"]/u);
});

test('cancellation escalates for a child ignoring INT and preserves its identity', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'yieldd-bootstrap-test-'));
    const controller = new AbortController();
    const reason = new Error('cancelled by test');
    const ready = join(directory, 'ready');
    const deadline = setTimeout(() => controller.abort(new Error('test readiness timed out')), 5000);
    let processResult;
    try {
        processResult = runProcess(process.execPath, ['-e', `
            process.on('SIGINT', () => {});
            require('node:fs').writeFileSync(process.argv[1], String(process.pid));
            setInterval(() => {}, 1000);
        `, ready], { env: runnerEnvironment(directory, directory), signal: controller.signal, graceMilliseconds: 10 });
        // Observe publication from the child rather than assuming it has installed its signal handler.
        const { watch } = require('node:fs');
        const pid = await new Promise((resolve, reject) => {
            const finish = (error, value) => {
                watcher.close();
                controller.signal.removeEventListener('abort', abort);
                if (error) reject(error); else resolve(value);
            };
            const check = () => readFile(ready, 'utf8').then(value => {
                if (/^[0-9]+$/u.test(value) && Number(value) > 1) finish(null, Number(value));
            }, () => {});
            const watcher = watch(directory, check);
            const abort = () => finish(controller.signal.reason);
            controller.signal.addEventListener('abort', abort, { once: true });
            check();
            processResult.then(() => finish(new Error('Child exited before readiness')), finish);
        });
        controller.abort(reason);
        await assert.rejects(processResult, error => error === reason);
        assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
    } finally {
        clearTimeout(deadline);
        controller.abort(reason);
        await processResult?.catch(() => {});
        await rm(directory, { recursive: true, force: true });
    }
});

test('default cancellation grace leaves time for supervisor cleanup before the outer kill', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'yieldd-bootstrap-test-'));
    const supervisor = spawn(process.execPath, ['-e', `
        const { runProcess } = require(process.argv[1]);
        const { rm } = require('node:fs/promises');
        const controller = new AbortController();
        for (const signal of ['SIGINT', 'SIGTERM']) {
            process.on(signal, () => controller.abort(new Error('cancelled')));
        }
        runProcess(process.execPath, ['-e', \`
            process.on('SIGINT', () => {});
            process.on('SIGTERM', () => {});
            console.log(process.pid);
            setInterval(() => {}, 1000);
        \`], { env: {}, signal: controller.signal })
            .catch(() => { process.exitCode = 1; })
            .finally(() => rm(process.argv[2], { recursive: true, force: true }));
    `, require.resolve('./index.cjs'), directory], { stdio: ['ignore', 'pipe', 'inherit'] });
    const exited = once(supervisor, 'exit');
    const lines = createInterface({ input: supervisor.stdout });
    const readinessDeadline = setTimeout(() => supervisor.kill('SIGKILL'), 5000);
    let terminate;
    let kill;
    let childPID;
    try {
        const [line] = await Promise.race([
            once(lines, 'line'),
            exited.then(() => { throw new Error('Supervisor exited before child readiness'); }),
        ]);
        assert.match(line, /^[0-9]+$/u);
        childPID = Number(line);
        assert.ok(childPID > 1);
        clearTimeout(readinessDeadline);
        supervisor.kill('SIGINT');
        terminate = setTimeout(() => supervisor.kill('SIGTERM'), 7500);
        kill = setTimeout(() => supervisor.kill('SIGKILL'), 10000);
        assert.deepEqual(await exited, [1, null], 'Supervisor must exit before the outer process kills it');
        await assert.rejects(stat(directory), { code: 'ENOENT' });
        assert.throws(() => process.kill(childPID, 0), { code: 'ESRCH' });
    } finally {
        clearTimeout(readinessDeadline);
        clearTimeout(terminate);
        clearTimeout(kill);
        lines.close();
        supervisor.kill('SIGKILL');
        await exited;
        if (childPID) {
            try { process.kill(-childPID, 'SIGKILL'); } catch (error) {
                if (error.code !== 'ESRCH') throw error;
            }
        }
        await rm(directory, { recursive: true, force: true });
    }
});
