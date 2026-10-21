// 皮卡鱼象棋引擎 Worker
// 主线程 postMessage 发 UCI 指令，Worker 返回 bestmove
importScripts('engine/pikafish.js');

let engineReady = false;
let waitingResolve = null;

// 等 Module 初始化
function waitModule() {
  return new Promise(resolve => {
    if (typeof Module !== 'undefined' && Module.send_command) {
      resolve(Module);
    } else {
      const timer = setInterval(() => {
        if (typeof Module !== 'undefined' && Module.send_command) {
          clearInterval(timer);
          resolve(Module);
        }
      }, 50);
    }
  });
}

waitModule().then(mod => {
  engineReady = true;
  // 让引擎输出 bestmove 时通知主线程
  mod.on_stdout = (line) => {
    if (line.startsWith('bestmove')) {
      postMessage({ type: 'bestmove', move: line.split(' ')[1] });
    } else if (line.startsWith('info')) {
      // 可选：把思考过程传回去
      // postMessage({ type: 'info', line });
    }
  };
  postMessage({ type: 'ready' });
});

onmessage = async (e) => {
  const { cmd, fen, depth } = e.data;
  if (!engineReady) return;

  if (cmd === 'position') {
    Module.send_command('position fen ' + fen);
  } else if (cmd === 'go') {
    Module.send_command('go depth ' + (depth || 15));
  } else if (cmd === 'uci') {
    Module.send_command('uci');
  } else if (cmd === 'stop') {
    Module.send_command('stop');
  }
};
