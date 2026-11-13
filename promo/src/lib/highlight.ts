import { color } from '../theme';

export type TokenKind =
  | 'command'
  | 'subcommand'
  | 'flag'
  | 'string'
  | 'number'
  | 'keyword'
  | 'key'
  | 'punct'
  | 'comment'
  | 'plain';

export type Token = { text: string; kind: TokenKind };

export const TOKEN_COLOR: Record<TokenKind, string> = {
  command: color.cyan,
  subcommand: color.amber,
  flag: color.violet,
  string: color.green,
  number: color.amber,
  keyword: color.pink,
  key: color.blue,
  punct: color.faint,
  comment: color.faint,
  plain: color.fg,
};

const scan = (source: string, pattern: RegExp, classify: (match: RegExpExecArray) => TokenKind) => {
  const tokens: Token[] = [];
  let cursor = 0;
  for (const match of source.matchAll(pattern)) {
    if (match.index > cursor) tokens.push({ text: source.slice(cursor, match.index), kind: 'plain' });
    tokens.push({ text: match[0], kind: classify(match) });
    cursor = match.index + match[0].length;
  }
  if (cursor < source.length) tokens.push({ text: source.slice(cursor), kind: 'plain' });
  return tokens;
};

const SHELL = /("[^"]*"?|'[^']*'?)|(\s+)|(--?[A-Za-z][\w-]*)|(\+[a-z]+)|(\b\d+\b)|(--|\|\||&&|\|)|([^\s"']+)/g;

export const tokenizeShell = (source: string): Token[] => {
  let seenCommand = false;
  return scan(source, SHELL, (match) => {
    if (match[1]) return 'string';
    if (match[2]) return 'plain';
    if (match[3]) return 'flag';
    if (match[4]) return 'subcommand';
    if (match[5]) return 'number';
    if (match[6]) return 'punct';
    if (seenCommand) return 'plain';
    seenCommand = true;
    return 'command';
  });
};

const JSON_PATTERN = /("(?:[^"\\]|\\.)*")(\s*:)?|(-?\d+(?:\.\d+)?)|(\btrue\b|\bfalse\b|\bnull\b)|([{}[\],:…])/g;

export const tokenizeJson = (source: string): Token[] => {
  const tokens: Token[] = [];
  for (const token of scan(source, JSON_PATTERN, (match) => {
    if (match[1]) return match[2] ? 'key' : 'string';
    if (match[3]) return 'number';
    if (match[4]) return 'keyword';
    return 'punct';
  })) {
    // The key pattern swallows its colon to tell keys from string values;
    // hand the colon back so it is dimmed like the other punctuation.
    if (token.kind === 'key' && token.text.endsWith(':')) {
      tokens.push({ text: token.text.slice(0, -1), kind: 'key' }, { text: ':', kind: 'punct' });
    } else {
      tokens.push(token);
    }
  }
  return tokens;
};

const TOML = /(#.*$)|(^\s*\[[^\]]+\])|("[^"]*")|(\b\d+(?:\.\d+)?\b)|(\btrue\b|\bfalse\b)|(=)|(^\s*[\w.-]+)/g;

export const tokenizeToml = (source: string): Token[] =>
  scan(source, TOML, (match) => {
    if (match[1]) return 'comment';
    if (match[2]) return 'subcommand';
    if (match[3]) return 'string';
    if (match[4]) return 'number';
    if (match[5]) return 'keyword';
    if (match[6]) return 'punct';
    return 'key';
  });

const RC = /(#.*$)|("[^"]*"|'[^']*')|(\$\{?[\w]+\}?)|(^\s*(?:export|source|alias|plugins|bindkey|autoload|eval|setopt|zstyle|bind|set|unbind|if|fi|then|run-shell)\b)/g;

// Shell rc and tmux.conf share enough shape for one loose tokenizer.
export const tokenizeRc = (source: string): Token[] =>
  scan(source, RC, (match) => {
    if (match[1]) return 'comment';
    if (match[2]) return 'string';
    if (match[3]) return 'number';
    return 'keyword';
  });

export const takeTokens = (tokens: Token[], count: number): Token[] => {
  const taken: Token[] = [];
  let remaining = count;
  for (const token of tokens) {
    if (remaining <= 0) break;
    taken.push(remaining >= token.text.length ? token : { ...token, text: token.text.slice(0, remaining) });
    remaining -= token.text.length;
  }
  return taken;
};
