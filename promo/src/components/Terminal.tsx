import type { CSSProperties } from 'react';
import { TOKEN_COLOR, takeTokens, tokenizeJson, tokenizeShell, type Token } from '../lib/highlight';
import { cursorOpacity, typedLength } from '../lib/typing';
import { alpha, color } from '../theme';

export const Tokens = ({ tokens, emphasize = [] }: { tokens: Token[]; emphasize?: string[] }) => (
  <>
    {tokens.map((token, index) => {
      const marked = token.kind === 'key' && emphasize.includes(token.text.replaceAll('"', ''));
      return (
        <span
          key={index}
          style={{
            color: marked ? color.amber : TOKEN_COLOR[token.kind],
            backgroundColor: marked ? alpha(color.amber, 16) : undefined,
            borderRadius: marked ? 4 : undefined,
          }}
        >
          {token.text}
        </span>
      );
    })}
  </>
);

export const Cursor = ({ opacity = 1, tone = color.cyan }: { opacity?: number; tone?: string }) => (
  <span
    style={{
      display: 'inline-block',
      width: '0.58em',
      height: '1.15em',
      marginLeft: '0.08em',
      verticalAlign: 'text-bottom',
      backgroundColor: tone,
      boxShadow: `0 0 0.7em ${alpha(tone, 70)}`,
      opacity,
    }}
  />
);

type PromptLineProps = {
  text: string;
  frame: number;
  from: number;
  to: number;
  symbol?: string;
  showCursor?: boolean;
  style?: CSSProperties;
};

export const PromptLine = ({ text, frame, from, to, symbol = '›', showCursor = true, style }: PromptLineProps) => {
  const count = typedLength(text, frame, from, to);
  const typing = frame > from && frame < to;
  return (
    <div style={{ whiteSpace: 'pre', ...style }}>
      <span style={{ color: color.cyan, fontWeight: 700 }}>{symbol} </span>
      <Tokens tokens={takeTokens(tokenizeShell(text), count)} />
      {showCursor ? <Cursor opacity={cursorOpacity(frame, typing)} /> : null}
    </div>
  );
};

export const JsonLines = ({ lines, emphasize, style }: { lines: string[]; emphasize?: string[]; style?: CSSProperties }) => (
  <div style={{ whiteSpace: 'pre', ...style }}>
    {lines.map((line) => (
      <div key={line}>
        <Tokens tokens={tokenizeJson(line)} emphasize={emphasize} />
      </div>
    ))}
  </div>
);
