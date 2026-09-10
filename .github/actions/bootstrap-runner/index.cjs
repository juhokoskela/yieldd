const { spawn } = require('node:child_process');
const { createHash } = require('node:crypto');
const { createReadStream } = require('node:fs');
const { mkdtemp, mkdir, writeFile, access, rm } = require('node:fs/promises');
const { tmpdir } = require('node:os');
const { join } = require('node:path');

const version = '2.337.0';
const packages = {
    'darwin-x64': ['osx-x64', 'd383f505d7ed041b1873ab68c35dd766fc093f2252330f95bb427be8f2c6dcfc'],
    'darwin-arm64': ['osx-arm64', '5a2cd92908a93d7276a194e1de6008099f3e7946f3f8e14aa7a1a7b4a31fdec2'],
    'linux-x64': ['linux-x64', '70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613'],
    'linux-arm64': ['linux-arm64', '9b1dc70626422526e3c94767cf024896beb15da5342a3f4819bf2feac13e0393'],
};

function validateConfiguration(encoded, name) {
    if (typeof name !== 'string' || !/^yieldd-bootstrap-[a-z0-9-]+$/u.test(name) ||
        /[^a-z0-9-]/u.test(name) || name.length > 64) {
        throw new Error('runner-name must be a unique yieldd-bootstrap- identifier, at most 64 characters.');
    }
    try {
        const files = JSON.parse(Buffer.from(encoded, 'base64').toString('utf8'));
        if (!files || Array.isArray(files) || Object.keys(files).some(key => !/^\.[a-z_]+$/u.test(key))) {
            throw new Error();
        }
        const decoded = JSON.parse(Buffer.from(files['.runner'], 'base64').toString('utf8'));
        const settings = new Map();
        for (const [key, value] of Object.entries(decoded)) {
            // Runner settings are case-insensitive; reject ambiguous aliases before passing the original payload on.
            const property = key.toLowerCase();
            if (settings.has(property)) throw new Error();
            settings.set(property, value);
        }
        const ephemeral = settings.get('ephemeral');
        if (settings.get('agentname') !== name || settings.get('workfolder') !== '_work' ||
            !(ephemeral === true || (typeof ephemeral === 'string' && ephemeral.trim().toLowerCase() === 'true'))) {
            throw new Error();
        }
    } catch {
        throw new Error('JIT configuration must describe the expected ephemeral runner with work folder _work.');
    }
}

function runnerEnvironment(home, temporary) {
    return {
        HOME: home, TMPDIR: temporary, TMP: temporary, TEMP: temporary,
        PATH: '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin',
        LANG: 'en_US.UTF-8',
    };
}

function signalGroup(pid, signal) {
    if (!pid) return;
    try { process.kill(-pid, signal); } catch (error) {
        if (error.code !== 'ESRCH') throw error;
    }
}

function runProcess(executable, args, { cwd, env, signal, graceMilliseconds = 10000 }) {
    signal.throwIfAborted();
    return new Promise((resolve, reject) => {
        const child = spawn(executable, args, { cwd, env, detached: true, stdio: 'inherit' });
        let escalation;
        const stop = () => {
            signalGroup(child.pid, 'SIGINT');
            escalation ??= setTimeout(() => signalGroup(child.pid, 'SIGKILL'), graceMilliseconds);
        };
        signal.addEventListener('abort', stop, { once: true });
        const finish = error => {
            clearTimeout(escalation);
            signal.removeEventListener('abort', stop);
            if (signal.aborted) reject(signal.reason);
            else if (error) reject(error);
            else resolve();
        };
        child.once('error', () => finish(new Error('Failed to launch a bootstrap process.')));
        child.once('exit', (code, exitSignal) => {
            // The listener can exit while descendants remain; never leave its group running.
            signalGroup(child.pid, 'SIGKILL');
            finish(code === 0 ? null : new Error(`Bootstrap process exited with ${exitSignal || `status ${code}`}.`));
        });
    });
}

async function verifyArchive(path, expected) {
    const hash = createHash('sha256');
    for await (const chunk of createReadStream(path)) hash.update(chunk);
    if (hash.digest('hex') !== expected) throw new Error('Runner archive checksum mismatch.');
}

async function bootstrap(encoded, name, signal) {
    validateConfiguration(encoded, name);
    const selected = packages[`${process.platform}-${process.arch}`];
    if (!selected) throw new Error('This prototype supports Linux and macOS on x64 or ARM64.');
    const directory = await mkdtemp(join(tmpdir(), 'yieldd-bootstrap-'));
    try {
        const home = join(directory, 'home');
        const temporary = join(directory, 'tmp');
        const runner = join(directory, 'runner');
        for (const path of [home, temporary, runner]) await mkdir(path, { mode: 0o700 });
        const env = runnerEnvironment(home, temporary);
        const options = { cwd: runner, env, signal };
        const archive = join(directory, 'runner.tar.gz');
        const [platform, checksum] = selected;
        await runProcess('/usr/bin/curl', [
            '--fail', '--location', '--silent', '--show-error', '--proto', '=https',
            '--connect-timeout', '15', '--max-time', '180', '--output', archive,
            `https://github.com/actions/runner/releases/download/v${version}/actions-runner-${platform}-${version}.tar.gz`,
        ], options);
        await verifyArchive(archive, checksum);
        signal.throwIfAborted();
        await runProcess('/usr/bin/tar', ['-xzf', archive, '-C', runner], options);
        const startedHook = join(home, 'started.sh');
        const completedHook = join(home, 'completed.sh');
        await writeFile(startedHook, '#!/bin/sh\n: > "$HOME/job-started"\n', { mode: 0o700 });
        await writeFile(completedHook, '#!/bin/sh\n: > "$HOME/job-completed"\n', { mode: 0o700 });
        console.log('Starting one nested runner. The original workflow owns its job logs and conclusion.');
        await runProcess(join(runner, 'bin/Runner.Listener'), ['run'], {
            ...options,
            env: {
                ...env,
                // Runner 2.337.0 consumes and removes this variable before executing jobs.
                ACTIONS_RUNNER_INPUT_JITCONFIG: encoded,
                ACTIONS_RUNNER_HOOK_JOB_STARTED: startedHook,
                ACTIONS_RUNNER_HOOK_JOB_COMPLETED: completedHook,
            },
        });
        await access(join(home, 'job-started'));
        await access(join(home, 'job-completed'));
        console.log('Nested runner exited after a job. Check the original workflow for its result.');
    } finally {
        await rm(directory, { recursive: true, force: true });
    }
}

if (require.main === module) {
    const encoded = process.env['INPUT_JIT-CONFIG'];
    const name = process.env['INPUT_RUNNER-NAME'];
    delete process.env['INPUT_JIT-CONFIG'];
    const controller = new AbortController();
    const interrupt = () => controller.abort(new Error('Bootstrap interrupted.'));
    for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(signal, interrupt);
    const timer = setTimeout(() => controller.abort(new Error('Bootstrap exceeded its 15-minute limit.')), 15 * 60 * 1000);
    bootstrap(encoded, name, controller.signal).catch(error => {
        console.error(error.message);
        process.exitCode = 1;
    }).finally(() => {
        clearTimeout(timer);
        for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.off(signal, interrupt);
    });
}

module.exports = { validateConfiguration, runnerEnvironment, runProcess, verifyArchive };
