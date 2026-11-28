import type { ReactNode } from 'react';

// Drawn as strokes rather than typed as glyphs: the bundled Latin font
// subsets carry no arrows, check marks or key symbols.
type IconProps = { size?: number; color?: string; strokeWidth?: number };

const Svg = ({ size = 20, color = 'currentColor', strokeWidth = 1.8, children }: IconProps & { children: ReactNode }) => (
  <svg
    width={size}
    height={size}
    viewBox="0 0 24 24"
    fill="none"
    stroke={color}
    strokeWidth={strokeWidth}
    strokeLinecap="round"
    strokeLinejoin="round"
    style={{ flexShrink: 0 }}
  >
    {children}
  </svg>
);

export const CheckIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M5 12.5l4.5 4.5L19 7.5" />
  </Svg>
);

export const BlockIcon = (props: IconProps) => (
  <Svg {...props}>
    <circle cx="12" cy="12" r="8.5" />
    <path d="M6 18L18 6" />
  </Svg>
);

export const ArrowRightIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M4 12h15M13 6l6 6-6 6" />
  </Svg>
);

export const ReturnIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M19 5v7a3 3 0 0 1-3 3H5M9 11l-4 4 4 4" />
  </Svg>
);

export const FolderIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M3 7.5A1.5 1.5 0 0 1 4.5 6h4.2l2 2.2h8.8A1.5 1.5 0 0 1 21 9.7v7.8a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 17.5z" />
  </Svg>
);

export const BranchIcon = (props: IconProps) => (
  <Svg {...props}>
    <circle cx="7" cy="5.5" r="2.2" />
    <circle cx="7" cy="18.5" r="2.2" />
    <circle cx="17" cy="8.5" r="2.2" />
    <path d="M7 7.7v8.6M17 10.7c0 3.4-4.2 3.3-10 4.3" />
  </Svg>
);

export const TerminalIcon = (props: IconProps) => (
  <Svg {...props}>
    <rect x="3" y="4.5" width="18" height="15" rx="2.5" />
    <path d="M7.5 9.5l3 2.5-3 2.5M13 15h3.5" />
  </Svg>
);

export const AgentIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M12 3.5l1.9 5.1 5.1 1.9-5.1 1.9L12 17.5l-1.9-5.1L5 10.5l5.1-1.9z" />
    <path d="M18.5 16.5v4M16.5 18.5h4" />
  </Svg>
);

export const DiffIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M8 4v8M4 8h8M5 18h7M16 5v14M13 16l3 3 3-3" />
  </Svg>
);

export const ChipIcon = (props: IconProps) => (
  <Svg {...props}>
    <rect x="7" y="7" width="10" height="10" rx="1.5" />
    <path d="M10 3.5V7M14 3.5V7M10 17v3.5M14 17v3.5M3.5 10H7M3.5 14H7M17 10h3.5M17 14h3.5" />
  </Svg>
);

export const GlobeIcon = (props: IconProps) => (
  <Svg {...props}>
    <circle cx="12" cy="12" r="8.5" />
    <path d="M3.5 12h17M12 3.5c2.6 2.4 3.8 5.2 3.8 8.5s-1.2 6.1-3.8 8.5c-2.6-2.4-3.8-5.2-3.8-8.5S9.400 5.900 12 3.500z" />
  </Svg>
);

export const SearchIcon = (props: IconProps) => (
  <Svg {...props}>
    <circle cx="10.5" cy="10.5" r="6" />
    <path d="M15 15l5 5" />
  </Svg>
);

export const LockIcon = (props: IconProps) => (
  <Svg {...props}>
    <rect x="5" y="10.5" width="14" height="9.5" rx="2" />
    <path d="M8.500 10.500V7.500a3.500 3.500 0 0 1 7 0v3" />
  </Svg>
);

export const BellIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M18 8a6 6 0 0 0-12 0c0 6-2.5 8-2.5 8h17S18 14 18 8" />
    <path d="M10.3 20a2 2 0 0 0 3.4 0" />
  </Svg>
);

export const BellOffIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M8.7 4.2A6 6 0 0 1 18 8c0 2.5.6 4.4 1.2 5.7M6 8c0 6-2.5 8-2.5 8h12" />
    <path d="M10.3 20a2 2 0 0 0 3.4 0M3 3l18 18" />
  </Svg>
);

export const BookmarkIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M6.5 4.5h11a1 1 0 0 1 1 1v15l-6.5-4-6.5 4v-15a1 1 0 0 1 1-1z" />
  </Svg>
);

export const ShieldIcon = (props: IconProps) => (
  <Svg {...props}>
    <path d="M12 3.5l7 3v5.5c0 4.5-3 7.5-7 9-4-1.5-7-4.5-7-9V6.5l7-3z" />
    <path d="M9.5 12.2l1.8 1.8 3.6-3.8" />
  </Svg>
);
