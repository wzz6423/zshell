# Music attribution

`electric-dreams-tour.mp3` is an excerpt from **Electric Dreams** by **Scott
Buckley** (2020), released under the **Creative Commons Attribution 4.0
International** license.

- Track and license statement: https://www.scottbuckley.com.au/library/electric-dreams/
- Original full mix: https://www.scottbuckley.com.au/library/wp-content/uploads/2020/09/sb_electricdreams.mp3
- License: https://creativecommons.org/licenses/by/4.0/
- Changes: one continuous excerpt from 00:00 to 02:40, a 0.8-second fade-in,
  a 3-second fade-out beginning at excerpt time 02:37, and a 2 dB gain reduction.
- Playback asset: 48 kHz stereo MP3 at 320 kb/s. No rearrangement, added beats,
  loops or changes to playback speed.

## Publication credit

Include this credit in the description of any published video using the score.
The author's license statement specifically requires it in YouTube descriptions.

> 'Electric Dreams' by Scott Buckley - released under CC-BY 4.0.
> www.scottbuckley.com.au. https://creativecommons.org/licenses/by/4.0/
> 00:00–02:40 excerpt. [Attribution and edit details](https://github.com/wzz6423/zshell/blob/main/promo/public/audio/ATTRIBUTION.md).

## Recreate the asset

Download the original full mix from the source above to an external temporary
directory as `sb_electricdreams.mp3`. From `promo/`, run:

```sh
ffmpeg -y -i /path/to/sb_electricdreams.mp3 -t 160 \
  -af 'atrim=duration=160,asetpts=PTS-STARTPTS,volume=-2dB,afade=t=in:st=0:d=0.8,afade=t=out:st=157:d=3' \
  -ar 48000 -ac 2 -c:a libmp3lame -b:a 320k -map_metadata -1 \
  -metadata title='Electric Dreams (Zshell feature tour excerpt)' \
  -metadata artist='Scott Buckley' -metadata date='2020' -metadata genre='Synthwave' \
  -metadata comment="'Electric Dreams' by Scott Buckley - CC BY 4.0. www.scottbuckley.com.au. https://creativecommons.org/licenses/by/4.0/; continuous 00:00-02:40 excerpt, 0.8-second fade-in, 3-second fade-out, -2 dB gain. Source: https://www.scottbuckley.com.au/library/electric-dreams/" \
  public/audio/electric-dreams-tour.mp3
```

The music license applies to this audio asset separately from the repository's
code license. Keep this attribution with redistributed copies.
