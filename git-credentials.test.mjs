import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { mkdir, mkdtemp, readFile, stat, symlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'
import { apply } from './git-credentials.mjs'

const here = dirname(fileURLToPath(import.meta.url))

async function sandbox() {
  const root = await mkdtemp(join(tmpdir(), 'git-credentials-'))
  const secretsDir = join(root, 'secrets')
  const workspaceRoot = join(root, 'workspace')
  const homeDir = join(root, 'home')
  await writeFile(join(root, '.keep'), '')
  await import('node:fs/promises').then(({ mkdir }) =>
    Promise.all([mkdir(secretsDir, { recursive: true }), mkdir(workspaceRoot, { recursive: true }), mkdir(homeDir, { recursive: true })]),
  )
  return {
    root,
    secretsDir,
    workspaceRoot,
    homeDir,
    outputDir: join(homeDir, '.dsh', 'git'),
  }
}

const files = {
  token: 'ghp_default',
  gitlabToken: 'glpat_a+b',
}

test('writes a default profile, a project override and an ssh project', async () => {
  const box = await sandbox()
  await writeFile(join(box.secretsDir, 'team_ed25519'), 'key', { mode: 0o600 })
  await writeFile(join(box.secretsDir, 'known_hosts'), 'git.example.com ssh-ed25519 AAAA\n')

  const manifest = {
    default: { provider: 'github', auth: 'https', token: files.token, identity: { name: 'Vlad', email: 'vlad@example.com' } },
    projects: {
      'web-app': { provider: 'gitlab', auth: 'https', host: 'gitlab.example.com', token: files.gitlabToken },
      infra: {
        provider: 'gitea',
        auth: 'ssh',
        host: 'git.example.com',
        key: 'team_ed25519',
        known_hosts: 'known_hosts',
        identity: { name: 'Vlad', email: 'vlad@example.com' },
      },
    },
  }

  const summary = await apply(manifest, box)
  assert.deepEqual(summary, ['default=github/https', 'web-app=gitlab/https', 'infra=gitea/ssh'])

  const gitconfig = await readFile(join(box.outputDir, 'gitconfig'), 'utf8')
  assert.match(gitconfig, /helper = store --file=.*default\.credentials/)
  assert.match(gitconfig, new RegExp(`includeIf "gitdir:${box.workspaceRoot}/web-app/"`))
  assert.match(gitconfig, new RegExp(`includeIf "gitdir:${box.workspaceRoot}/infra/"`))
  assert.match(gitconfig, /name = Vlad/)

  const defaultCreds = await readFile(join(box.outputDir, 'credentials', 'default.credentials'), 'utf8')
  assert.equal(defaultCreds, 'https://x-access-token:ghp_default@github.com\n')
  assert.equal((await stat(join(box.outputDir, 'credentials', 'default.credentials'))).mode & 0o077, 0)

  const project = await readFile(join(box.outputDir, 'projects', '00-web-app.gitconfig'), 'utf8')
  assert.match(project, /helper = store --file=.*00-web-app\.credentials/)
  const projectCreds = await readFile(join(box.outputDir, 'credentials', '00-web-app.credentials'), 'utf8')
  assert.equal(projectCreds, 'https://oauth2:glpat_a%2Bb@gitlab.example.com\n')

  const ssh = await readFile(join(box.outputDir, 'projects', '01-infra.gitconfig'), 'utf8')
  assert.match(ssh, /sshCommand = ssh -i .*team_ed25519/)
  assert.match(ssh, /StrictHostKeyChecking=yes/)
  assert.match(ssh, /UserKnownHostsFile=.*known_hosts/)

  const include = await readFile(join(box.homeDir, '.gitconfig'), 'utf8')
  assert.match(include, /\[include\]/)
  assert.match(include, /\.dsh\/git\/gitconfig/)

  await apply(manifest, box)
  const again = await readFile(join(box.homeDir, '.gitconfig'), 'utf8')
  assert.equal(again.split('.dsh/git/gitconfig').length - 1, 1)
})

test('requires a host for providers without a default', async () => {
  const box = await sandbox()
  await assert.rejects(
    apply({ default: { provider: 'gitea', auth: 'https', token: 'x' } }, box),
    /needs "host"/,
  )
})

test('requires credentials for https', async () => {
  const box = await sandbox()
  await assert.rejects(
    apply({ default: { provider: 'github', auth: 'https' } }, box),
    /needs "token" or "token_file"/,
  )
})

test('requires key and known_hosts for ssh', async () => {
  const box = await sandbox()
  await assert.rejects(
    apply({ projects: { web: { provider: 'gitea', auth: 'ssh', host: 'git.example.com', key: 'missing', known_hosts: 'missing' } } }, box),
    /cannot read key/,
  )
})

test('reads a token file relative to the secrets directory', async () => {
  const box = await sandbox()
  await writeFile(join(box.secretsDir, 'token'), 'from-file\n')
  const summary = await apply(
    { default: { provider: 'github', auth: 'https', token_file: 'token' } },
    box,
  )
  assert.deepEqual(summary, ['default=github/https'])
  const creds = await readFile(join(box.outputDir, 'credentials', 'default.credentials'), 'utf8')
  assert.match(creds, /from-file/)
})

test('a project helper overrides the default for the same host', async () => {
  const box = await sandbox()
  await mkdir(join(box.workspaceRoot, 'web-app'), { recursive: true })
  const manifest = {
    default: { provider: 'github', auth: 'https', token: 'default-token' },
    projects: { 'web-app': { provider: 'github', auth: 'https', token: 'project-token' } },
  }
  await apply(manifest, box)
  const repo = join(box.workspaceRoot, 'web-app', 'repo')
  await mkdir(repo, { recursive: true })
  execFileSync('git', ['init', '-q'], { cwd: repo })
  const output = execFileSync('git', ['credential', 'fill'], {
    cwd: repo,
    input: 'protocol=https\nhost=github.com\npath=org/repo.git\n',
    env: { ...process.env, HOME: box.homeDir, GIT_TERMINAL_PROMPT: '0' },
    encoding: 'utf8',
  })
  assert.match(output, /^password=project-token$/m)
})

test('rejects project paths that escape the workspace root', async () => {
  const box = await sandbox()
  await assert.rejects(
    apply({ projects: { '../outside': { provider: 'github', token: 'x' } } }, box),
    /escapes the workspace root/,
  )
})

test('host profiles scope each token to its own host', async () => {
  const box = await sandbox()
  const manifest = {
    default: { provider: 'github', auth: 'https', token: 'ghp_default' },
    hosts: { 'gitlab.com': { provider: 'gitlab', auth: 'https', token: 'glpat_second' } },
  }
  const summary = await apply(manifest, box)
  assert.deepEqual(summary, ['default=github/https', 'gitlab.com=gitlab/https'])
  const config = await readFile(join(box.outputDir, 'gitconfig'), 'utf8')
  assert.match(config, /\[credential "https:\/\/gitlab\.com"\]/)

  const fill = (host) => execFileSync('git', ['credential', 'fill'], {
    cwd: box.homeDir,
    input: `protocol=https\nhost=${host}\n\n`,
    env: { ...process.env, HOME: box.homeDir, GIT_TERMINAL_PROMPT: '0' },
    encoding: 'utf8',
  })
  assert.match(fill('github.com'), /^password=ghp_default$/m)
  assert.match(fill('gitlab.com'), /^password=glpat_second$/m)
})

test('ssh host profiles share one wrapper that picks the key by host', async () => {
  const box = await sandbox()
  await writeFile(join(box.secretsDir, 'github_ed25519'), 'key', { mode: 0o600 })
  await writeFile(join(box.secretsDir, 'gitlab_ed25519'), 'key', { mode: 0o600 })
  await writeFile(join(box.secretsDir, 'known_hosts'), 'github.com ssh-ed25519 AAAA\n')

  const summary = await apply({
    hosts: {
      'github.com': { provider: 'github', auth: 'ssh', key: 'github_ed25519', known_hosts: 'known_hosts' },
      'gitlab.com': { provider: 'gitlab', auth: 'ssh', key: 'gitlab_ed25519', known_hosts: 'known_hosts' },
    },
  }, box)
  assert.deepEqual(summary, ['github.com=github/ssh', 'gitlab.com=gitlab/ssh'])

  const config = await readFile(join(box.outputDir, 'gitconfig'), 'utf8')
  assert.match(config, /sshCommand = .*ssh-wrapper\.sh/)

  const wrapper = await readFile(join(box.outputDir, 'ssh-wrapper.sh'), 'utf8')
  assert.match(wrapper, /github\.com\) exec ssh -i .*github_ed25519/)
  assert.match(wrapper, /gitlab\.com\) exec ssh -i .*gitlab_ed25519/)
  assert.match(wrapper, /\*\) exec ssh "\$@" ;;/)
  assert.equal((await stat(join(box.outputDir, 'ssh-wrapper.sh'))).mode & 0o777, 0o700)
})

test('a host profile whose "host" disagrees with the key is refused', async () => {
  const box = await sandbox()
  await assert.rejects(
    apply({
      hosts: { 'github.com': { provider: 'github', host: 'gitlab.com', auth: 'https', token: 'x' } },
    }, box),
    /must match the hosts key/,
  )
})

test('the CLI runs when invoked through a symlink (native install)', async () => {
  const box = await sandbox()
  await writeFile(join(box.secretsDir, 'profiles.json'), JSON.stringify({
    default: { provider: 'github', auth: 'https', token: 'ghp_symlink' },
  }))
  const link = join(box.root, 'dsh-git-credentials.mjs')
  await symlink(join(here, 'git-credentials.mjs'), link)

  const output = execFileSync(process.execPath, [link], {
    env: {
      ...process.env,
      HOME: box.homeDir,
      DSH_GIT_SECRETS: box.secretsDir,
      DSH_WORKSPACE: box.workspaceRoot,
    },
    encoding: 'utf8',
  })
  assert.match(output, /git credentials: default=github\/https/)
  await stat(join(box.homeDir, '.dsh', 'git', 'gitconfig'))
})
