import Foundation

extension KernelLanguages {
    public static var more: [KernelLanguage] { [javascript, ruby, bash, zsh] }

    public static let javascript = KernelLanguage(
        id: "javascript", command: ["node", "{script}"], fileExtension: "cjs", supportsCompletion: true,
        script: #"""
const vm = require('node:vm');
const util = require('node:util');
const { createRequire } = require('node:module');
const path = require('node:path');
let timers = new Set();
let abort = null;
const context = vm.createContext({
  console, process, Buffer, URL, TextEncoder, TextDecoder,
  fetch: globalThis.fetch, structuredClone: globalThis.structuredClone,
  require: createRequire(path.join(require('node:os').homedir(), '.folio-kernel.cjs')),
  setTimeout: (...args) => { const t = setTimeout(...args); timers.add(t); return t; },
  setInterval: (...args) => { const t = setInterval(...args); timers.add(t); return t; },
  clearTimeout: t => { clearTimeout(t); timers.delete(t); },
  clearInterval: t => { clearInterval(t); timers.delete(t); }
});
const lexical = new Set();
process.on('SIGINT', () => {
  if (abort) abort(new Error('Ausführung unterbrochen (SIGINT).'));
  for (const timer of timers) clearTimeout(timer);
  timers.clear();
});
function names(receiver) {
  if (!receiver) return [...new Set([...Object.getOwnPropertyNames(context), ...lexical])].sort();
  if (!/^[A-Za-z_$][\w$]*(\.[A-Za-z_$][\w$]*)*$/.test(receiver)) return [];
  try {
    let value = vm.runInContext(receiver, context, { breakOnSigint: true });
    const result = new Set();
    while (value != null) {
      for (const name of Object.getOwnPropertyNames(Object(value))) result.add(name);
      value = Object.getPrototypeOf(Object(value));
    }
    return [...result].sort();
  } catch (_) { return []; }
}
async function run(code) {
  timers = new Set();
  let script;
  try { script = new vm.Script(code, { filename: '<block>' }); }
  catch (error) {
    if (!(error instanceof SyntaxError) || !/\bawait\b/.test(code)) throw error;
    // Only the top-level-await fallback relaxes lexical declarations.
    const lifted = code.replace(/^(\s*)(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=/gm, '$1globalThis.$2 =');
    script = new vm.Script('(async () => {\n' + lifted + '\n})()', { filename: '<block>' });
  }
  for (const match of code.matchAll(/\b(?:const|let|var|function|class)\s+([A-Za-z_$][\w$]*)/g)) lexical.add(match[1]);
  const interrupted = new Promise((_, reject) => { abort = reject; });
  try {
    const value = await Promise.race([Promise.resolve(script.runInContext(context, { breakOnSigint: true })), interrupted]);
    if (value !== undefined) console.log(util.inspect(value));
  } finally { abort = null; }
}
async function handle(line) {
  let msg;
  try { msg = JSON.parse(line); } catch (_) { return; }
  let status = 'ok';
  try {
    if (msg.op === 'complete') console.log(JSON.stringify(names(msg.receiver || '')));
    else await run(msg.code || '');
  } catch (error) {
    status = 'error';
    console.error(error.stack || String(error));
  }
  const marker = '\x1e' + msg.id + ':' + status + '\n';
  await Promise.all([
    new Promise(resolve => process.stdout.write(marker, resolve)),
    new Promise(resolve => process.stderr.write(marker, resolve))
  ]);
}
let queue = Promise.resolve();
require('node:readline').createInterface({ input: process.stdin, terminal: false })
  .on('line', line => { queue = queue.then(() => handle(line)); });
"""#)

    public static let ruby = KernelLanguage(
        id: "ruby", command: ["ruby", "{script}"], fileExtension: "rb", supportsCompletion: true,
        script: #"""
require 'json'
$stdout.sync = true
$stderr.sync = true
scope = Object.new.instance_eval('binding')
running = false
trap('INT') { raise Interrupt, 'Ausführung unterbrochen (SIGINT).' if running }
STDIN.each_line do |line|
  begin
    msg = JSON.parse(line)
  rescue JSON::ParserError
    next
  end
  status = 'ok'
  begin
    running = true
    if msg['op'] == 'complete'
      receiver = msg['receiver'].to_s
      names = if receiver.empty?
        scope.local_variables + scope.eval('self').methods + scope.eval('self').private_methods
      elsif receiver.match?(/\A[a-zA-Z_]\w*(\.[a-zA-Z_]\w*)*\z/)
        begin
          scope.eval(receiver, '<block>').methods
        rescue NameError, NoMethodError
          []
        end
      else
        []
      end
      puts JSON.generate(names.map(&:to_s).uniq.sort)
    else
      value = scope.eval(msg['code'].to_s, '<block>', 1)
      puts "=> #{value.inspect}" unless value.nil?
    end
  rescue Exception => error
    status = 'error'
    warn "#{error.class}: #{error.message}"
    (error.backtrace || []).grep(/<block>/).each { |frame| warn frame }
  ensure
    running = false
    marker = "\x1e#{msg['id']}:#{status}"
    puts marker
    warn marker
  end
end
"""#)

    public static let bash = shell(id: "bash", command: ["bash", "--noprofile", "--norc", "{script}"])
    public static let zsh = shell(id: "zsh", command: ["zsh", "-f", "{script}"])

    private static func shell(id: String, command: [String]) -> KernelLanguage {
        KernelLanguage(id: id, command: command, fileExtension: id, supportsCompletion: true, script: #"""
__folio_run() {
    eval "$__folio_code"
}
trap 'if [ "$__folio_running" = 1 ]; then printf "%s\n" "Ausführung unterbrochen (SIGINT)." >&2; return 130; fi' INT
while IFS= read -r __folio_line; do
    # Decode fields into quoted shell literals.
    __folio_fields=$(printf '%s' "$__folio_line" | /usr/bin/perl -MJSON::PP -e '
        binmode STDOUT, ":encoding(UTF-8)"; local $/; my $m = eval { decode_json(<STDIN>) }; exit 1 unless ref($m) eq "HASH";
        for my $key (qw(id op code receiver)) {
            my $v = $m->{$key} // "";
            $v =~ s/\x27/\x27\\\x27\x27/g;
            print "__folio_$key=\x27$v\x27\n";
        }
    ') || continue
    eval "$__folio_fields"
    __folio_status=ok
    if [ "$__folio_op" = complete ]; then
        if [ -n "$__folio_receiver" ]; then
            printf '[]\n'
        else
            {
                if [ -n "${ZSH_VERSION-}" ]; then
                    eval 'print -l -- ${(k)parameters} ${(k)functions}'
                else
                    compgen -v
                    compgen -A function
                fi
            } | /usr/bin/perl -MJSON::PP -e 'my %n; while (<STDIN>) { chomp; $n{$_}=1 unless /^__folio_/; } print encode_json([sort keys %n]), "\n";'
        fi
    else
        __folio_running=1
        __folio_run
        __folio_exit=$?
        __folio_running=0
        if [ "$__folio_exit" -ne 0 ]; then
            __folio_status=error
            printf 'Befehl mit Status %s beendet.\n' "$__folio_exit" >&2
        fi
    fi
    printf '\036%s:%s\n' "$__folio_id" "$__folio_status"
    printf '\036%s:%s\n' "$__folio_id" "$__folio_status" >&2
done
"""#)
    }
}
