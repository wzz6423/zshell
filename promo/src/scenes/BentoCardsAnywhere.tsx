import { Keycap } from '../components/Hud';
import { ArrowRightIcon, CheckIcon, GlobeIcon, TerminalIcon } from '../components/Icons';
import { Cursor, PromptLine } from '../components/Terminal';
import { during, linear, pop, SPRING } from '../lib/motion';
import { cursorOpacity } from '../lib/typing';
import { alpha, color } from '../theme';
import type { CardProps } from './BentoCards';

const OPEN_AT = 48;
const REQUEST_AT = 232;
const APPROVE_AT = 306;
const CONNECT_AT = 334;
const PAIR_CODE = '2916-8402';

const TrafficLights = () => (
  <span style={{ display: 'flex', gap: 4 }}>
    {[color.red, color.amber, color.green].map((tone) => (
      <span key={tone} style={{ width: 6, height: 6, borderRadius: 999, backgroundColor: alpha(tone, 65) }} />
    ))}
  </span>
);

const SharedTerminal = ({ frame, phone = false }: { frame: number; phone?: boolean }) => (
  <div className="font-mono" style={{ fontSize: phone ? 11 : 18, lineHeight: phone ? 1.5 : 1.8, color: color.fg }}>
    <PromptLine text="ls src" frame={frame} from={378} to={418} showCursor={frame < 434} />
    <div style={{ color: color.muted, opacity: linear(frame, [434, 442]) }}>app.ts</div>
    <div style={{ color: color.muted, opacity: linear(frame, [442, 450]) }}>styles.css</div>
    <div style={{ opacity: linear(frame, [450, 458]), color: color.cyan }}>
      › <Cursor opacity={cursorOpacity(frame, false)} />
    </div>
  </div>
);

export const AnywhereCard = ({ frame, fps }: CardProps) => {
  const quick = pop(frame, fps, OPEN_AT, SPRING.snappy);
  const shortcut = during(frame, OPEN_AT - 8, OPEN_AT + 16, 5);
  const browser = linear(frame, [174, 194]);
  const enabled = pop(frame, fps, 198, SPRING.snappy);
  const requested = linear(frame, [REQUEST_AT + 10, REQUEST_AT + 20]);
  const settings = 1 - linear(frame, [318, CONNECT_AT]);
  const connected = linear(frame, [CONNECT_AT, CONNECT_AT + 14]);
  const approve = during(frame, APPROVE_AT - 6, APPROVE_AT + 16, 5);
  const request = during(frame, REQUEST_AT - 6, REQUEST_AT + 16, 5);

  return (
    <div style={{ position: 'relative', width: '100%', maxWidth: 620, height: 240, margin: '0 auto' }}>
      <div
        style={{ position: 'absolute', left: 0, right: 0, top: 0, height: 202, borderRadius: 12, overflow: 'hidden', backgroundColor: color.raised, border: `1px solid ${color.line}`, opacity: 1 - browser }}
      >
        <div className="font-sans" style={{ display: 'flex', alignItems: 'center', gap: 9, height: 28, padding: '0 12px', borderBottom: `1px solid ${color.line}`, fontSize: 12, color: color.muted }}>
          <TrafficLights />
          <GlobeIcon size={12} />
          Documentation
        </div>
        <div style={{ padding: '18px 20px', opacity: 1 - quick * 0.75 }}>
          <div className="font-sans" style={{ fontSize: 20, fontWeight: 600, color: color.muted }}>Your next idea.</div>
          {[76, 90, 62].map((width) => (
            <div key={width} style={{ width: `${width}%`, height: 6, borderRadius: 4, marginTop: 12, backgroundColor: alpha(color.fg, 9) }} />
          ))}
        </div>
        <div
          style={{ position: 'absolute', left: '7%', right: '7%', top: 38, bottom: 12, borderRadius: 11, overflow: 'hidden', backgroundColor: alpha(color.surface, 97), border: `1px solid ${color.lineStrong}`, boxShadow: `0 14px 28px ${alpha(color.shadow, 14)}`, opacity: Math.min(1, quick * 1.4), transform: `translateY(${(1 - quick) * -28}px) scale(${0.95 + quick * 0.05})` }}
        >
          <div className="font-sans" style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '7px 12px', fontSize: 13, color: color.fg, borderBottom: `1px solid ${color.line}` }}>
            <TerminalIcon size={14} color={color.cyan} />
            Quick Terminal
          </div>
          <div className="font-mono" style={{ padding: '10px 14px', fontSize: 17, lineHeight: 1.7 }}>
            <PromptLine text="git status --short" frame={frame} from={72} to={112} showCursor={frame < 124} />
            <div style={{ opacity: linear(frame, [124, 134]), color: color.muted }}><span style={{ color: color.amber }}> M</span> src/app.ts</div>
            <div style={{ opacity: linear(frame, [134, 144]), color: color.cyan }}>› <Cursor opacity={cursorOpacity(frame, false)} /></div>
          </div>
        </div>
      </div>

      <div style={{ position: 'absolute', left: 0, right: 0, top: 0, height: 204, opacity: browser }}>
        <div style={{ position: 'absolute', left: 0, right: 184, top: 0, height: 202, borderRadius: 12, overflow: 'hidden', backgroundColor: color.surface, border: `1px solid ${color.lineStrong}` }}>
          <div className="font-sans" style={{ height: 29, display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 10, padding: '0 12px', fontSize: 13, color: color.muted, backgroundColor: color.raised, borderBottom: `1px solid ${color.line}` }}>
            <TrafficLights />
            <span>{frame < CONNECT_AT ? 'Settings · Browser Access' : 'launch — zsh'}</span>
            <span style={{ fontSize: 12 }}>Mac</span>
          </div>
          <div className="font-sans" style={{ position: 'absolute', left: 14, right: 14, top: 42, opacity: settings }}>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', fontSize: 16, color: color.fg }}>
              Enable browser access
              <span style={{ position: 'relative', width: 32, height: 18, borderRadius: 999, backgroundColor: enabled > 0.5 ? color.blue : alpha(color.fg, 16) }}>
                <span style={{ position: 'absolute', top: 2, left: 2, width: 14, height: 14, borderRadius: 999, backgroundColor: color.surface, transform: `translateX(${14 * enabled}px)` }} />
              </span>
            </div>
            <div style={{ marginTop: 8, fontSize: 13, color: color.muted }}>LAN · HTTPS</div>
            <div style={{ marginTop: 14, opacity: requested }}>
              <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', fontSize: 15, color: color.fg }}>
                <span>Phone <span className="font-mono" style={{ marginLeft: 8, fontSize: 16, color: color.blue }}>{PAIR_CODE}</span></span>
                <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5, padding: '5px 10px', borderRadius: 7, fontSize: 13, backgroundColor: color.blue, color: color.surface, transform: `scale(${1 - approve * 0.06})`, boxShadow: `0 0 ${22 * approve}px ${alpha(color.blue, 35)}` }}>
                  {frame >= APPROVE_AT + 10 ? <CheckIcon size={12} /> : null}
                  Approve
                </span>
              </div>
              <div style={{ marginTop: 6, fontSize: 12, color: color.muted }}>Pairing Requests</div>
            </div>
          </div>
          {/* Browser access lists main-window panes, so this replaces the independent Quick Terminal. */}
          <div style={{ position: 'absolute', left: 16, right: 16, top: 47, opacity: connected }}>
            <SharedTerminal frame={frame} />
          </div>
        </div>

        <div style={{ position: 'absolute', right: 148, top: 88, color: color.blue, opacity: requested, transform: `translateX(${connected * 4}px)` }}><ArrowRightIcon size={28} /></div>

        <div style={{ position: 'absolute', right: 0, top: -2, width: 140, height: 207, padding: 7, borderRadius: 21, backgroundColor: color.raised, border: `2px solid ${color.lineStrong}`, boxShadow: `0 8px 20px ${alpha(color.shadow, 9)}`, transform: `translateY(${(1 - pop(frame, fps, 180, SPRING.snappy)) * 16}px)` }}>
          <div style={{ height: 4, width: 30, margin: '0 auto 6px', borderRadius: 999, backgroundColor: alpha(color.fg, 20) }} />
          <div style={{ height: 176, borderRadius: 12, padding: '7px 8px', overflow: 'hidden', backgroundColor: color.surface }}>
            <div className="font-sans" style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', fontSize: 12, fontWeight: 650, color: color.fg }}>
              Zshell
              {frame >= CONNECT_AT ? <CheckIcon size={12} color={color.green} /> : <GlobeIcon size={12} color={color.muted} />}
            </div>
            {frame < CONNECT_AT ? (
              <div className="font-sans" style={{ paddingTop: 10, color: color.fg }}>
                <div style={{ fontSize: 13, fontWeight: 600 }}>Browser Access</div>
                <div style={{ marginTop: 9, fontSize: 10, color: color.muted }}>Client name</div>
                <div style={{ padding: '4px 6px', marginTop: 3, border: `1px solid ${color.lineStrong}`, borderRadius: 5, fontSize: 12 }}>Phone</div>
                <div style={{ marginTop: 7, padding: '6px 3px', borderRadius: 6, fontSize: 12, textAlign: 'center', color: color.surface, backgroundColor: color.blue, transform: `scale(${1 - request * 0.05})` }}>Request Pairing</div>
                <div className="font-mono" style={{ marginTop: 9, fontSize: 14, textAlign: 'center', color: color.blue, opacity: requested }}>{PAIR_CODE}</div>
              </div>
            ) : (
              <div style={{ opacity: connected }}>
                <div className="font-sans" style={{ marginTop: 6, fontSize: 10, color: color.green }}>Connected</div>
                <div className="font-sans" style={{ marginTop: 7, fontSize: 9, color: color.muted }}>Terminal session</div>
                <div className="font-sans" style={{ marginTop: 3, padding: '4px 5px', fontSize: 11, borderRadius: 5, border: `1px solid ${color.lineStrong}`, color: color.fg }}>launch — zsh</div>
                <div style={{ marginTop: 8 }}><SharedTerminal frame={frame} phone /></div>
              </div>
            )}
          </div>
        </div>
      </div>

      <div className="font-sans" style={{ position: 'absolute', left: 0, right: 0, bottom: 0, height: 28, display: 'flex', justifyContent: 'center', alignItems: 'center', gap: 10, fontSize: 16, color: color.muted }}>
        {frame < 184 ? (
          <>
            <Keycap size={12} pressed={shortcut}>Cmd</Keycap><Keycap size={12} pressed={shortcut}>I</Keycap>
            <span>From any app <span style={{ marginLeft: 8 }}>随时唤出</span></span>
          </>
        ) : frame < CONNECT_AT ? (
          <span>Pair on your Mac <span style={{ marginLeft: 8 }}>从 Mac 批准配对</span></span>
        ) : (
          <span>One terminal, both screens <span style={{ marginLeft: 8 }}>同一个 Mac 终端</span></span>
        )}
      </div>
    </div>
  );
};
