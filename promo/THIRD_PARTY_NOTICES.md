# Third-party notices for the product video

The code in this folder is under the repository's [MIT License](../LICENSE.txt). The terms below cover the tools, materials and generated content it uses. They were checked against official sources on 2026-09-30.

## Remotion (build tool)

[Remotion](https://www.remotion.dev) is installed by `npm ci` and not committed here. It's licensed under the [Remotion License](https://github.com/remotion-dev/remotion/blob/main/LICENSE.md); see also [remotion.dev/license](https://www.remotion.dev/license).

- **Free licence:** for "an individual", "a for-profit organization with up to 3 employees", non-profits, and evaluation.
- **Company License:** everyone else needs one to use Remotion "for the purpose of creating videos and images".
- **Who it applies to:** whoever builds the video. Check your own eligibility before you run `script/build-promo-video.sh`.
- **The published film:** it was made by an individual (Remotion free licence).

## Inter (typeface used in the film's own text)

The film's titles and labels use [Inter](https://github.com/rsms/inter), Copyright 2016 The Inter Project Authors. Inter is licensed under the [SIL Open Font License 1.1](https://openfontlicense.org/open-font-license-official-text/).
- **Installed by:** `npm ci`, through `@fontsource-variable/inter`, whose licence field is `OFL-1.1`. The font files aren't committed here.
- **In the film:** only rendered text appears; no font software is distributed with it.

## Narration: Google Gemini TTS (AI-generated voice)

The narration masters in `vo/` were generated with Google Gemini TTS, using model `gemini-3.1-flash-tts-preview` and prebuilt voice Kore. They were made through Vertex AI under the standard Google Cloud terms.
- **Model status:** the model was in [public preview](https://cloud.google.com/blog/products/ai-machine-learning/gemini-3-1-flash-tts-on-google-cloud), and its audio carries Google's SynthID watermark.
- **Disclosure:** the narration is disclosed as AI-generated here, in the root README and in the release notes.

The applicable terms:
- **Ownership** ([Google Cloud Service Specific Terms](https://cloud.google.com/terms/service-terms), last modified 2026-09-24): §20(a) defines "Generated Output" as Customer Data, and states that "Google does not assert any ownership rights in any new intellectual property created in the Generated Output."
- **Preview status** (same terms): §5 makes Pre-GA Offerings available "as is", with no SLA or indemnity.
- **Use and disclosure of output:** the [Additional Terms for Generative AI Preview Products](https://cloud.google.com/terms/genai-preview-products) normally limit preview products to evaluation and testing, with no disclosure of Generated Output to third parties. However, they state that those restrictions "do not apply to Gemini Enterprise Agent Platform (formerly Vertex AI) when used with" the Pre-GA models listed there, which include "Gemini 3.1 Flash TTS".
- **Prohibited uses:** the [Generative AI Prohibited Use Policy](https://policies.google.com/terms/generative-ai/use-policy) is incorporated by §20(c). Among other things, it forbids "misrepresenting the provenance of generated content by claiming it was created solely by a human, in order to deceive", which is why the narration is labelled.

## Apple trademarks and the app icons in the UI renders

The UI renders show WinMux's real interface managing demo windows of Apple's built-in apps: Mail, Calendar, Messages, Safari, Notes, TextEdit, Preview, Terminal and Freeform. WinMux shows each window's app icon, so those icons appear in the renders. From 62.6 to 75.2 s, two loupes magnify the pinned tiles, icons included. The icons belong to Apple and aren't covered by this repository's MIT License.

Apple's [Guidelines for Using Apple Trademarks and Copyrights](https://www.apple.com/legal/intellectual-property/guidelinesfor3rdparties.html) don't allow Apple-owned icons in promotional materials without a licence from Apple. They do let a developer "show an image of an Apple product in your promotional/advertising materials to depict that your product is compatible with, or otherwise works with, the Apple product", on four conditions:
1. The product really works with it.
2. The image is genuine, not an artist's rendering.
3. The Apple product is shown in the best light.
4. Nothing suggests endorsement by Apple.

The film relies on that allowance:
- **Works with:** WinMux manages these apps' windows, and the film shows it doing that.
- **Genuine:** the icons are the ones macOS draws for these apps, captured from WinMux's views and not redrawn. No icon files are included here.
- **Best light:** they're unmodified, at the size and position WinMux draws them (scaled with the rest of the UI), and never used as a mark for WinMux.
- **No endorsement:** see the notice below.

The repository's README screenshots show these icons in the same way. If Apple objects, the renders can be remade with other apps.

Apple, Mac, macOS, Safari and the names of the apps above are trademarks of Apple Inc., registered in the U.S. and other countries and regions. WinMux isn't affiliated with, sponsored by or endorsed by Apple.

## Music

The music was composed and synthesized in code for this film by `scripts/music/`. It uses no samples, loops or third-party audio, and it's covered by the repository's MIT License.

## WinMux logo and UI

The logo is rebuilt from `resources/winmux-logo.svg`, and the UI renders come from this repository's own views. The logo and WinMux's own interface in the renders are covered by the repository's MIT License. Two things in the renders aren't: the third-party app icons (see above), and the glyphs of the macOS system font that the interface text is drawn in.
