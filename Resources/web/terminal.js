const host = document.getElementById('terminal');
const term = new Terminal({fontFamily:'Menlo, monospace',fontSize:13,cursorBlink:true,scrollback:3000,
    theme:{background:'#18231e',foreground:'#edf2e9',cursor:'#b7e3c6',selectionBackground:'#466656',black:'#27342d',green:'#a8deb4',blue:'#9dc7ed'}});
const emit = (kind,value) => webkit.messageHandlers.pty.postMessage({kind,value});
term.open(host);
function fit() {
  const screen = host.querySelector('.xterm-screen');
  const cw = screen?.offsetWidth / term.cols, ch = screen?.offsetHeight / term.rows;
  if (!cw || !ch || host.clientWidth<30 || host.clientHeight<30) return;
  const cols = Math.max(2,Math.floor((host.clientWidth-16)/cw)), rows = Math.max(1,Math.floor(host.clientHeight/ch));
  if (cols!==term.cols || rows!==term.rows) term.resize(cols,rows);
  emit('size',[term.cols,term.rows]);
}
term.onData(s=>emit('input',s));
function receive(data){ term.write(Uint8Array.from(atob(data),c=>c.charCodeAt(0))); }
function ended(){term.writeln('\r\n\x1b[2m会话已结束，按回车重新打开。\x1b[0m');}
new ResizeObserver(fit).observe(host);
fit(); emit('ready',[term.cols,term.rows]); term.focus();
