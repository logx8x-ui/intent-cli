# Intent AI Worker

This Cloudflare Worker keeps the model credential out of the Mac app and turns a short description plus the local installed-app catalog into editable Intent drafts.

## Deploy

```bash
npm install
npx wrangler login
npx wrangler secret put OPENROUTER_API_KEY
npm run deploy
```

The default model is `openai/gpt-5.6-luna`. Change `OPENROUTER_MODEL` in `wrangler.jsonc` to test another compatible structured-output model. Never commit `.dev.vars` or API keys.

## Verify

```bash
npm test
curl https://intent-ai.logx8x.workers.dev/health
```

Requests are rate limited per random installation identifier. Prompt content is not logged by the Worker, and OpenRouter routing requires zero-data-retention providers that do not use submitted data for training.
