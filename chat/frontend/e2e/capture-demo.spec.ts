import { expect, test } from '@playwright/test'

/**
 * Not a test but a recorder, so the evidence survives after the AWS stack is torn
 * down. Excluded from the normal suite by playwright.config.ts; run it with:
 *
 *   npm run capture
 *
 * It writes docs/evidence/chat-window-{left,right}.png at the repo root, plus
 * one video per window into docs/evidence/video/, which
 * scripts/make-demo-gif.sh stitches side by side into docs/demo.gif.
 *
 * Sends are spaced out. The stills cannot show older messages sliding up, so
 * the video has to, and back-to-back sends would blur the animations together.
 */
test('capture two windows side by side', async ({ browser }) => {
  const size = { width: 560, height: 620 }

  // A directory per window: Playwright names video files by hash, so writing
  // both into one directory would leave nothing to tell left from right.
  const video = (side: string) => ({ dir: `../../docs/evidence/video/${side}`, size })

  const leftContext = await browser.newContext({ viewport: size, recordVideo: video('left') })
  const rightContext = await browser.newContext({ viewport: size, recordVideo: video('right') })
  const left = await leftContext.newPage()
  const right = await rightContext.newPage()

  for (const [page, name] of [
    [left, 'Alice'],
    [right, 'Bob'],
  ] as const) {
    await page.goto('/')
    const field = page.getByLabel('Your display name')
    await field.fill(name)
    await field.blur()
    await expect(page.getByRole('status')).toContainText('Connected')
  }

  const send = async (page: typeof left, body: string) => {
    await page.getByRole('textbox', { name: 'Message', exact: true }).fill(body)
    await page.getByRole('button', { name: 'Send' }).click()
    // Assert on both windows, so the recording never runs ahead of the delivery
    // it is supposed to be showing.
    await expect(left.getByRole('log')).toContainText(body)
    await expect(right.getByRole('log')).toContainText(body)
    await page.waitForTimeout(1200)
  }

  await send(left, 'Hello from the left window.')
  await send(right, 'And this arrived over the WebSocket.')
  await send(left, 'Older messages slide up to make room.')
  await send(right, 'Both windows share one server.')

  await left.screenshot({ path: '../../docs/evidence/chat-window-left.png' })
  await right.screenshot({ path: '../../docs/evidence/chat-window-right.png' })

  // Videos are only flushed to disk on context close.
  await leftContext.close()
  await rightContext.close()
})
