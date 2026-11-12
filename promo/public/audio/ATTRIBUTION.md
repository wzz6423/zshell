# Music attribution

`tears-in-rain.mp3` is an excerpt from **Tears in Rain** by **Scott Buckley**
(2019), released under the **Creative Commons Attribution 4.0 International**
license.

- Track and license statement: https://www.scottbuckley.com.au/library/tears-in-rain/
- Original full mix: https://www.scottbuckley.com.au/library/wp-content/uploads/2019/07/sb_tearsinrain.mp3
- License: https://creativecommons.org/licenses/by/4.0/
- Changes: one continuous excerpt from 00:32 to 01:22, a 0.8-second fade-in,
  a 3-second fade-out beginning at excerpt time 00:47, and a 1 dB gain reduction.
- Playback asset: 48 kHz stereo MP3 at 320 kb/s. No rearrangement, added beats,
  loops or changes to playback speed.

## Publication credit

Include this credit in the description of any published video using the score.
The author's license statement specifically requires it in YouTube descriptions.

> 'Tears In Rain' by Scott Buckley - released under CC-BY 4.0.
> www.scottbuckley.com.au. https://creativecommons.org/licenses/by/4.0/
> 00:32–01:22 excerpt, with fades and reduced gain.

## Recreate the asset

Download the original full mix from the source above to an external temporary
directory as `sb_tearsinrain.mp3`. From `promo/`, run:

```sh
ffmpeg -y -ss 32 -i /path/to/sb_tearsinrain.mp3 -t 50 \
  -af 'atrim=duration=50,asetpts=PTS-STARTPTS,volume=-1dB,afade=t=in:st=0:d=0.8,afade=t=out:st=47:d=3' \
  -ar 48000 -ac 2 -c:a libmp3lame -b:a 320k -map_metadata -1 \
  -metadata title='Tears in Rain (Zshell launch film excerpt)' \
  -metadata artist='Scott Buckley' -metadata date='2019' \
  -metadata comment="'Tears In Rain' by Scott Buckley - CC BY 4.0. www.scottbuckley.com.au. https://creativecommons.org/licenses/by/4.0/; 00:32-01:22 excerpt with fades and -1 dB gain." \
  public/audio/tears-in-rain.mp3
```

The music license applies to this audio asset separately from the repository's
code license. Keep this attribution with redistributed copies.
