// A bounded excerpt of an opted-in user instruction, never an assistant/tool output.
// No model call or transcript read runs on the synchronous hook path.
const path = require('node:path');

function taskLabelFromPrompt(value) {
  if (typeof value !== 'string') return null;
  let text = value.slice(0, 8192);
  // Automatic messages and pasted reference material are not a new user task.
  text = text.replace(/<(task-notification|teammate-message|system-reminder|pasted_content|local-command-stdout|local-command-stderr|environment_context)\b[^>]*>[\s\S]*?(?:<\/\1\b[^>]*>|$)/gi, ' ')
    .replace(/```[\s\S]*?(?:```|$)|~~~[\s\S]*?(?:~~~|$)/g, ' ')
    .replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, '')
    .replace(/[\x00-\x08\x0b-\x1f\x7f-\x9f\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, ' ')
    .replace(/\b(?:https?|ssh):\/\/[^\s<>"'`]+/gi, '[链接]')
    .replace(/\b(?:sk-(?:proj-|ant-)?|gh[pousr]_|github_pat_)[A-Za-z0-9_-]{8,}/g, '[已隐藏]')
    .replace(/(?:\b(?:api[_-]?key|token|password|secret)|密钥|密码)\s*[:=：]\s*(?:"[^"]*"|'[^']*'|[^\s,，;；]+)/gi, '[已隐藏]')
    .replace(/`([^`\n]+)`/g, (_, code) => /^(?:~?\/|[A-Za-z]:\\)/.test(code)
      ? path.posix.basename(code.replace(/\\/g, '/').replace(/\/+$/, ''))
      : /^[\p{L}\p{N}_.@+-]+$/u.test(code) ? code : '[代码]')
    .replace(/(^|[\s([：:])(?:~?\/|[A-Za-z]:\\)[^\s`"'<>，。；、)\]]+/gm,
      match => match.replace(/(?:~?\/|[A-Za-z]:\\).*/, filename => path.posix.basename(filename.replace(/\\/g, '/').replace(/\/+$/, ''))));
  text = text.split(/\r?\n/).map(line => line.replace(/^\s*(?:#{1,6}\s+|[-*]\s+|\d+[.)、]\s*)/, '').trim()).find(Boolean) || '';
  text = text.replace(/\*\*|__|`/g, '').replace(/\s+/g, ' ').trim();
  if (!text || /^(?:继续|好的?|可以|行|嗯|是的|确认|收到|开始吧|没问题|谢谢|ok|yes|continue|go ahead|thanks|thank you)[\s，。.!！~～]*$/i.test(text)) return null;
  const chars = Array.from(text);
  return chars.length > 32 ? chars.slice(0, 32).join('') + '…' : text;
}

module.exports = { taskLabelFromPrompt };
