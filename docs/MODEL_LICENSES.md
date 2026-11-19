# Model licenses

_Checked 2026-11-18 against `Packages/LLMCore/Sources/LLMCore/Catalog/ModelCatalog.swift`. The catalog is the source of truth; update this file when it changes._

This app does not ship any model weights. It lists five presets. When you tap **Download** and confirm, it fetches that preset's files from Hugging Face. It pulls them from the [mlx-community](https://huggingface.co/mlx-community) MLX conversion, at a pinned commit. The files stay in the app's private storage on your device. In the app, every model card shows a license badge that links to the license text. **Settings › About › Model licenses** lists all presets.

**v1 policy:** a preset's upstream model must be licensed under **Apache-2.0 or MIT**. Models whose licenses add use restrictions, attribution duties tied to "making available" a product, or revenue limits are excluded (see [Excluded models](#excluded-models)).

> The license readings below are an engineering summary, not legal advice. Whether an app that only starts a user-initiated download from Hugging Face "distributes" or "makes available" a model is an interpretation that has not been checked by a lawyer.

## Presets

All presets are 4-bit MLX conversions. "Download" is the app's `downloadBytes`: the sum of the files the app actually fetches (`*.safetensors`, `*.json`, `*.jinja`) at the pinned revision. This is the number shown in the download prompt. Hugging Face's page for the repo shows a slightly larger total because it also counts README and similar files.

| Preset | Catalog id | MLX repo | Pinned revision | Download | Upstream model | License |
|---|---|---|---|---:|---|---|
| Qwen3 0.6B | `qwen3-0.6b-4bit` | [mlx-community/Qwen3-0.6B-4bit](https://huggingface.co/mlx-community/Qwen3-0.6B-4bit) | `73e3e38d981303bc594367cd910ea6eb48349da8` | 349,711,765 B (≈ 350 MB) | [Qwen/Qwen3-0.6B](https://huggingface.co/Qwen/Qwen3-0.6B) | Apache-2.0 ([LICENSE](https://huggingface.co/Qwen/Qwen3-0.6B/blob/main/LICENSE)) |
| Qwen3 1.7B | `qwen3-1.7b-4bit` | [mlx-community/Qwen3-1.7B-4bit](https://huggingface.co/mlx-community/Qwen3-1.7B-4bit) | `3b1b1768f8f8cf8351c712464f906e86c2b8269e` | 982,341,391 B (≈ 982 MB) | [Qwen/Qwen3-1.7B](https://huggingface.co/Qwen/Qwen3-1.7B) | Apache-2.0 |
| SmolLM3 3B | `smollm3-3b-4bit` | [mlx-community/SmolLM3-3B-4bit](https://huggingface.co/mlx-community/SmolLM3-3B-4bit) | `d3a7e0594d6642dbcfb7d149bed8b0bdf49f95ce` | 1,747,378,363 B (≈ 1.75 GB) | [HuggingFaceTB/SmolLM3-3B](https://huggingface.co/HuggingFaceTB/SmolLM3-3B) | Apache-2.0 (per the model card) |
| Phi-4-mini (3.8B) | `phi-4-mini-4bit` | [mlx-community/Phi-4-mini-instruct-4bit](https://huggingface.co/mlx-community/Phi-4-mini-instruct-4bit) | `ac1c269cb4222a4e136a3d09edad301056c1f36a` | 2,177,574,851 B (≈ 2.18 GB) | [microsoft/Phi-4-mini-instruct](https://huggingface.co/microsoft/Phi-4-mini-instruct) | MIT ([LICENSE](https://huggingface.co/microsoft/Phi-4-mini-instruct/blob/main/LICENSE)); upstream also ships a `NOTICE.md` |
| Qwen3 4B | `qwen3-4b-4bit` | [mlx-community/Qwen3-4B-4bit](https://huggingface.co/mlx-community/Qwen3-4B-4bit) | `4dcb3d101c2a062e5c1d4bb173588c54ea6c4d25` | 2,277,297,903 B (≈ 2.28 GB) | [Qwen/Qwen3-4B](https://huggingface.co/Qwen/Qwen3-4B) | Apache-2.0 |

Notes:
- **License sources.** The upstream license column comes from the research notes of 2026-11-18, which read each upstream LICENSE file or model card. The mlx-community repos carry the matching `apache-2.0` / `mit` tag. The Qwen3 LICENSE files are the standard Apache-2.0 text with "Copyright 2024 Alibaba Cloud".
- **Badge links.** In the app, the Apache-2.0 badge opens the generic license text at <https://www.apache.org/licenses/LICENSE-2.0>. The Phi-4-mini badge opens the upstream LICENSE file.
- **The 4B preset.** It is the hybrid-thinking `Qwen3-4B-4bit`, not `Qwen3-4B-Instruct-2507`. The latter was considered in the research notes but is not what the catalog ships.
- **Run on a phone.** On 2026-11-18 all five presets ran inside this app on an iPhone 18 Pro Max (iOS 27.2.1). Each was downloaded from the pinned revision, loaded and completed the three-turn device self-test. The catalog's `verifiedOnDevice` comments record this; before that, each preset had only a static check against mlx-swift-lm 3.31.3 and a tokenizer-only template render on the Mac. Speeds and caveats are in the README's Performance and Known limitations sections. SmolLM3 3B and Phi-4-mini have not been tried in Chinese.

### What the licenses ask of this app

**Apache-2.0** (Qwen3 0.6B / 1.7B / 4B, SmolLM3 3B)
- **Redistribution conditions.** Section 4 sets conditions that apply when you *redistribute* the work or derivatives. You must give recipients a copy of the license, keep copyright and attribution notices, mark modified files, and pass on any `NOTICE` file.
- **This app does not redistribute.** It does not bundle or re-host the weights. The user downloads them directly from Hugging Face, so these conditions are not obviously triggered. Showing the license per model (badge + Model licenses screen) is good practice either way.
- **No trademark rights.** Section 6 grants no trademark rights, so do not use "Qwen" or "SmolLM" in the app's name or icon. This also matches App Review Guidelines 4.1(c) and 5.2.1.

**MIT** (Phi-4-mini)
- **Notice in copies.** The copyright and permission notice must be included in copies or substantial portions of the software. This applies to copies the app would distribute, and the app distributes none.
- **Before you change the setup.** Read upstream's `NOTICE.md` before bundling or re-hosting the weights.

**If this ever changes:** if a future version bundles weights in the app or serves them from its own server, the redistribution conditions above apply directly. Ship the license texts and notices with the weights.

## Excluded models

These models would load with the pinned library (static check) and are popular, but their licenses were judged incompatible with the strict v1 policy. The summaries are paraphrases with section numbers. Read the linked texts for the exact wording.

| Model(s) | License | Why excluded (paraphrased) | Source |
|---|---|---|---|
| Llama 3.2 1B / 3B Instruct | Llama 3.2 Community License | §1.b.i: anyone who distributes or makes available the Llama Materials, or a product or service that contains them, must provide a copy of the agreement and prominently display "Built with Llama". §1.b.iii: a specific copyright notice text must accompany it. §1.b.iv: use must follow Meta's Acceptable Use Policy, which the license incorporates by reference. §2: extra terms apply above 700 million monthly active users. | <https://raw.githubusercontent.com/meta-llama/llama-models/main/models/llama3_2/LICENSE> |
| Gemma 3 (1B), Gemma 3n (E2B / E4B) | Gemma Terms of Use (last modified April 1, 2026) | §1.1(b): "Distribution" includes making Gemma or its functionality available by electronic or remote means. §3.1: anyone distributing must put the Gemma use restrictions into their own terms as an enforceable provision, give notice to users, and ship a "Notice" file. §3.2: use must follow the Gemma Prohibited Use Policy. Google also reserves the right to restrict usage remotely. | <https://ai.google.dev/gemma/terms> |
| LFM2, LFM2.5, LFM3 (Liquid AI) | LFM Open License v1.0 | §5(a)/(b): commercial use is licensed only while the licensee's annual revenue stays below a threshold of USD 10,000,000. Above it, commercial use is not licensed. Otherwise the license is Apache-like, with attribution and NOTICE duties. | <https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct/blob/main/LICENSE> |
| EXAONE 4.0 1.2B | EXAONE AI Model License | §3.1: no commercial use of the model, derivatives or output, including in apps that earn revenue directly or indirectly. Derivatives must also carry "EXAONE" at the start of their name. | <https://huggingface.co/LGAI-EXAONE/EXAONE-4.0-1.2B/blob/main/LICENSE> |

Notes:
- **Gated on Hugging Face.** Upstream `meta-llama/*` and `google/gemma-*` repos are gated (manual approval). The mlx-community copies are not, but that does not change the license.
- **Interpretation.** Whether a download-on-request app triggers these clauses is the interpretation flagged at the top of this file. They are excluded so that v1 does not depend on it.

### Not excluded by license, but deferred

| Model | License | Why not in v1 |
|---|---|---|
| Gemma 4 E2B (`mlx-community/gemma-4-e2b-it-4bit`) | Apache-2.0. Gemma 4 is **not** under the Gemma Terms of Use; its `license_link` renders plain Apache-2.0, even though the mlx-community tag says `gemma`. | The current repo revision (2026-07-06) drops weights that mlx-swift-lm 3.31.3 requires, and quantizes a layer 3.31.3 cannot load. Both are fixed in 3.31.4. It is also about 3.58 GB. Candidate after the library upgrade. |
| Qwen3.5 0.8B / 2B / 4B (`*-MLX-4bit`) | Apache-2.0 | 3.31.3 lacks several Qwen 3.5 numerical fixes (fp32 gated-delta state and others) that landed in 3.31.4–3.32.3. Candidate after upgrading to ≥ 3.32.3, preferably 3.33.0. |
| DeepSeek-R1-Distill-Qwen-1.5B | MIT (derived from Qwen2.5, Apache-2.0) | Reasoning-only distill, weak at ordinary chat. The mlx-community repo has no license tag. |

Sources for the deferred models: <https://ai.google.dev/gemma/docs/gemma_4_license>, <https://github.com/ml-explore/mlx-swift-lm/pull/342>, <https://github.com/ml-explore/mlx-swift-lm/releases>.
