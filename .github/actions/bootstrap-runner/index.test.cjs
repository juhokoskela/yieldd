const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const { mkdtemp, writeFile, readFile, stat, rm } = require('node:fs/promises');
const { createHash } = require('node:crypto');
const { tmpdir } = require('node:os');
const { join } = require('node:path');
const { createInterface } = require('node:readline');
const { test } = require('node:test');
const { validateConfiguration, runnerEnvironment, runProcess, verifyArchive } = require('./index.cjs');

const name = 'yieldd-bootstrap-test';
function encodeSettings(settings) {
    return Buffer.from(JSON.stringify({
        '.runner': Buffer.from(JSON.stringify(settings)).toString('base64'),
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
        })).toString('base64'), ...files,
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
