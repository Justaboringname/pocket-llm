# Privacy Policy — Pocket LLM (draft)

[简体中文](PRIVACY.zh-CN.md)

<!-- TODO(owner): this is a draft. Replace the working name with the final app name, set the effective date, add the contact line, and publish it at a public URL (then set PRIVACY_POLICY_URL in Config/Base.xcconfig). -->

_Effective date: TODO — draft written 2026-11-18 to match the app's code at that date._

Pocket LLM runs language models on your iPhone. **We do not collect, receive or store any of your data.** The app has no accounts, no analytics, no advertising and no tracking. It contains no third-party analytics, advertising or crash-reporting SDKs.

## What is stored on your device

The app keeps the following in its private storage on your iPhone:

- **Your conversation.** This includes your messages, the model's replies (with any "thinking" text), and the name of the model that answered. The app keeps one conversation at a time.
- **Your chat settings.** These are the system prompt, temperature and maximum reply length, plus the name of the last model you used.
- **Downloaded model files** and small bookkeeping files for them.

None of this is sent to us or to anyone else by the app.

Information shown under **Settings › Device** is read on the device and only displayed. That includes the hardware model, memory figures, thermal state and whether the increased-memory entitlement is active.

**Backups.** Your conversation and settings are ordinary app data. If you use iCloud Backup or back up your iPhone to a computer, they are included in those backups like other apps' data. Apple or your computer handles those backups, not us. Model files are excluded from backups. After deleting the app or reinstalling, you download them again.

## When the app uses the network

The app connects to the internet only to download a model, and only after you tap **Download** and confirm.

- **What it fetches.** The app asks Hugging Face's servers (huggingface.co) for the model's file list, then downloads the files. Large files may be delivered from Hugging Face's download servers.
- **What it sends.** The app adds no account, token or identifier of its own to these requests, and they contain none of your conversations or settings. The app does not store cookies from these requests or send any back.
- **What Hugging Face receives.** Like any web server, Hugging Face receives your IP address, which files are requested, and a User-Agent string with the app's name and version. Hugging Face handles this under its own privacy policy: <https://huggingface.co/privacy>.

Loading a downloaded model and chatting with it do not use the network. The model-loading code is built so that it cannot download anything.

**Links.** The app shows links to model pages and license texts, and links to this policy and to support once they are published. Tapping one opens your web browser. A link that appears in a model reply also opens in your browser, but only if you tap it, and only for `http`/`https` links. Other kinds of links are ignored. The website you open has its own privacy policy.

**Sharing.** Copy and Share on a message use the standard iOS clipboard and share sheet. Text goes only where you choose to send it.

**Crash reports from Apple.** In iOS Settings you may have chosen to share analytics with app developers. If so, Apple may give the developer crash reports and diagnostics for this app. Apple collects and handles these under Apple's privacy policy. The app itself sends none.

## Deleting your data

- **Conversation.** Tap the new-conversation button (pencil icon) in the chat. It replaces the saved conversation with an empty one. There is no history of earlier conversations. Your settings, including the system prompt, are kept.
- **System prompt and settings.** Edit or clear them in **Settings**. "Reset to model defaults" clears your sampling overrides.
- **Models.** Open **Models** and tap the trash icon on a downloaded model.
- **Everything.** Delete the app. iOS then removes all of its data from the device. Copies inside existing iCloud or computer backups remain until those backups are replaced or deleted. You manage them in iOS Settings or on your computer.

## AI-generated content

Replies are generated on your device by small language models. They may be wrong or inappropriate. The app does not filter them. Do not rely on them for medical, legal, financial or other important decisions.

## Children

The app does not collect personal data from anyone, including children. <!-- TODO(owner): align with the final App Store age rating. -->

## Changes

If the app's handling of data changes, we will update this page and its effective date before the change ships.

## Contact

<!-- TODO(owner): contact email or support page URL -->
Questions about this policy: _TODO — contact address_.
