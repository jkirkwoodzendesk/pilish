# Terminal image previews

An explicitly enabled terminal client displays PNG previews directly, and JPEG, WebP and first-frame GIF previews with optional FFmpeg conversion. Completed tool results, attached prompt images and replayed history share the same renderer. Every preview that fully fits is displayed; unsupported formats retain placeholders. Graphical Emacs continues to use native images.

## Sub-features

- `opt-in`: disabling the mode emits no graphics and removes owned placements.
- `sources`: tool results, attached prompt images, and history use the same image preview rules.
- `formats`: PNG is direct; JPEG, WebP and first-frame GIF convert through optional FFmpeg.
- `conversion`: runtime, decoder pixels, output dimensions and output bytes are bounded; temporary files and failed processes are cleaned up.
- `visibility`: partially visible, folded, or hidden previews have no terminal placement.
- `lifecycle`: scrolling, resizing, workspace switches, window closure, and buffer teardown remove or reposition previews.
- `multiple`: multiple completely visible previews can coexist.
- `stable`: unrelated commands and edits leave unchanged placements intact.
- `fallback`: unsupported, invalid, oversized, unavailable-converter and failed-conversion images keep existing placeholders.

## How to get to it (user POV)

Use an isolated terminal Emacs with a Kitty-compatible outer terminal such as Ghostty. Open a disposable Pilish session and enable `M-x pilish-terminal-image-mode`. Read a PNG with Pi's read tool or attach a PNG to a prompt. Open the same saved session to exercise history. Disable the mode to clear placements.

## Driving it with Pilish harnesses

Preconditions: provision dependencies and run the Doctor described in the verification skill before GUI journeys. The terminal pixel check below is a separate manual lane, not evidence supplied by a graphical Emacs run. Use a disposable session, not the user's saved session or an unattended driver attached to their interactive Emacs.

```bash
make test-render SELECTOR=pilish-test-terminal-image VERBOSE=1
make test-render SELECTOR=image VERBOSE=1
```

Require all named terminal-image tests and the existing image tests to pass. Install FFmpeg for the two real conversion tests; skips block conversion verification. These cover all formats, first-frame GIF, shared rendering, placeholders, native GUI precedence, runtime/output limits, cleanup, cooling, chunked transport, and reconciliation; mocked terminal output does not prove displayed pixels.

For the manual terminal lane, record these user actions and observations in the run's evidence directory:

1. Start disabled; read a small PNG and observe a type-and-size placeholder.
2. Enable `pilish-terminal-image-mode`, then regenerate the result. Observe a PNG preview.
3. Read small PNG, JPEG, WebP and GIF files; verify their previews appear when their complete regions fit. Read an animated GIF and verify only its first frame appears. With `pilish-terminal-image-converter-program` set to nil, regenerate results: PNG must still work and other formats must retain their placeholders.
4. Scroll until a region is partly outside the window; verify its image disappears. Scroll back; verify it returns at the reserved rows.
5. Type or move point in another visible buffer; verify unchanged previews do not flash. Then switch Doom workspace or buffer; verify images do not remain on unrelated text. Return and verify restoration.
6. Resize, fold/unfold the result, and reload history; verify placements track the new visible regions.
7. Attach a PNG and a JPEG, WebP or GIF to prompts; verify their sent turns and replayed history.
8. Disable the mode, close the preview window, and kill the disposable transcript in separate runs; verify each action leaves no stale terminal images.

Run `make check` before committing. Preserve exact commands, outputs, and manual observations, including unrun steps and missing prerequisites.

## Gotchas

- Kitty support is asserted by opt-in, not discovered. SSH, tmux, and nested terminals require separate verification.
- FFmpeg is optional and must be on Emacs's `exec-path` or configured explicitly. Conversion is synchronous with a default two-second deadline per image; the timeout can accumulate across multiple images.
- Existing placeholder strings need regeneration after enabling. Disabling removes graphics but can leave reserved blank rows until regeneration.
- Layout uses a configurable approximate cell aspect ratio, not a terminal pixel query. Narrow windows can hide previews instead of resizing them.
- Timer-based placement can briefly hide moved or newly visible previews. Unchanged previews must survive unrelated commands and edits. Do not claim terminal pixels or performance from batch tests.
- A failed or unavailable Doctor blocks the standard GUI journey; report it rather than substituting a terminal result for a GUI pass.
