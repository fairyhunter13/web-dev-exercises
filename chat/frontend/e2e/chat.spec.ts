import { expect, test, type Browser, type Page } from '@playwright/test'

/**
 * Two windows, which is what the question asks to see.
 *
 * Each window is its own `browser.newContext()`. Separate contexts have
 * separate cookies, storage and localStorage, so each window gets its own
 * display name and its own WebSocket.
 *
 * There is no `waitForTimeout` below. Web-first assertions retry until they
 * pass or time out, which is what keeps a test over a network protocol
 * deterministic.
 *
 * Every message body carries a per-test tag. The server keeps a shared recent
 * transcript and replays it to anyone who joins, which is the behaviour test 3
 * exists to prove, so without a tag, tests running in parallel or a second run
 * against a still-warm server would see each other's messages. Tagging keeps
 * the suite parallel, and a leftover message from a manual poke at the app
 * cannot turn a green test red.
 */

let tag = ''
test.beforeEach(({}, testInfo) => {
  tag = `t${testInfo.testId}-${Date.now()}`
})

async function openChat(browser: Browser, name: string): Promise<Page> {
  const context = await browser.newContext()
  const page = await context.newPage()
  await page.goto('/')

  const nameField = page.getByLabel('Your display name')
  await nameField.fill(name)
  await nameField.blur()

  // Wait for the socket, not for a duration.
  await expect(page.getByRole('status')).toContainText('Connected')
  return page
}

async function say(page: Page, body: string) {
  await page.getByRole('textbox', { name: 'Message', exact: true }).fill(`${tag} ${body}`)
  await page.getByRole('button', { name: 'Send' }).click()
}

/** Only this test's messages, so a shared transcript cannot leak in. */
function mine(page: Page) {
  return page.getByRole('log', { name: 'Chat messages' }).locator('li', { hasText: tag })
}

/** A single tagged bubble. Asserting on one element keeps strict mode useful. */
function bubble(page: Page, body: string) {
  return mine(page).filter({ hasText: body })
}

test('a message sent in one window appears in the other', async ({ browser }) => {
  const alice = await openChat(browser, 'Alice')
  const bob = await openChat(browser, 'Bob')

  await say(alice, 'hello from Alice')
  await expect(bubble(bob, 'hello from Alice')).toBeVisible()
  await expect(bubble(bob, 'hello from Alice')).toContainText('Alice')

  // And back the other way, to prove the channel is not one-directional.
  await say(bob, 'hi Alice, from Bob')
  await expect(bubble(alice, 'hi Alice, from Bob')).toBeVisible()

  // The sender must see its own message exactly once. The optimistic copy is
  // rendered immediately and then replaced by the server echo; a bug in that
  // reconciliation shows up here as two.
  await expect(bubble(bob, 'hi Alice, from Bob')).toHaveCount(1)

  await alice.context().close()
  await bob.context().close()
})

test('older messages move up as new ones arrive', async ({ browser }) => {
  const alice = await openChat(browser, 'Alice')

  for (const body of ['first', 'second', 'third']) {
    await say(alice, body)
    await expect(bubble(alice, body)).toBeVisible()
  }

  // Order is asserted geometrically, not by DOM index: "old messages slide
  // upwards to make room" is a claim about where things end up on screen, and
  // a CSS regression that reversed the column would still pass an index check.
  const bubbles = mine(alice)
  await expect(bubbles).toHaveCount(3)

  // The measurement is polled rather than read once. boundingBox() is a
  // one-shot, non-retrying call, and each bubble is re-keyed from clientId to
  // the server-assigned id when the echo arrives, which detaches the element.
  // Locally that swap has already happened by the time the count assertion
  // passes; over CloudFront and API Gateway it can land in between, and the
  // read then returns null. Polling retries the read until both boxes exist.
  await expect
    .poll(async () => {
      const oldest = await bubbles.first().boundingBox()
      const newest = await bubbles.last().boundingBox()
      if (!oldest || !newest) return null
      return oldest.y < newest.y
    })
    .toBe(true)

  await expect(bubbles.first()).toContainText('first')
  await expect(bubbles.last()).toContainText('third')

  await alice.context().close()
})

test('a new window is sent the transcript it missed', async ({ browser }) => {
  // This is the reconnect-rehydration path, which is not optional on API
  // Gateway: its idle timeout is 10 minutes and connections are hard-capped at
  // 2 hours, so every long-lived client is eventually dropped and must catch up.
  const alice = await openChat(browser, 'Alice')
  await say(alice, 'sent before Bob arrived')
  await expect(bubble(alice, 'sent before Bob arrived')).toBeVisible()

  const bob = await openChat(browser, 'Bob')
  await expect(bubble(bob, 'sent before Bob arrived')).toBeVisible()

  await alice.context().close()
  await bob.context().close()
})

test('the composer stays disabled and the client retries when the socket will not open', async ({
  browser,
}) => {
  const context = await browser.newContext()
  const page = await context.newPage()

  // routeWebSocket intercepts the handshake, so the socket closes for real
  // rather than being simulated. `context.setOffline` is the obvious thing to
  // reach for here and does not work: it blocks new requests but leaves an
  // already-established WebSocket alone, so the test would pass against a
  // client with no reconnect logic at all.
  //
  // The pattern matches any socket rather than the local server's `/ws` path,
  // because the same suite runs against the deployed stack (E2E_BASE_URL),
  // where the endpoint is an API Gateway URL ending in `/live`. A path-specific
  // pattern silently matched nothing there and the test asserted on a
  // perfectly healthy connection.
  await page.routeWebSocket('**/*', (ws) => ws.close())
  await page.goto('/')

  await expect(page.getByRole('status')).toContainText('Reconnecting')
  await expect(page.getByRole('textbox', { name: 'Message', exact: true })).toBeDisabled()
  await expect(page.getByRole('button', { name: 'Send' })).toBeDisabled()

  await context.close()
})
