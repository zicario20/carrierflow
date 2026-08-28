import { expect, test } from "@playwright/test";

test("English operations shell exposes a keyboard skip path and 44px navigation targets", async ({ page }) => {
  const response = await page.goto("/");
  expect(response?.status()).toBe(200);

  const navigation = page.getByRole("navigation", { name: "Primary navigation" });
  await expect(navigation).toBeVisible();
  await expect(navigation.getByRole("link")).toHaveCount(6);
  await expect(navigation.getByRole("link", { name: "Plan" })).toHaveAttribute("href", "/settings/plan");

  await page.keyboard.press("Tab");
  const skipLink = page.getByRole("link", { name: "Skip to main content" });
  await expect(skipLink).toBeFocused();
  await page.keyboard.press("Enter");
  await expect(page.getByRole("main", { name: "Operations workspace" })).toBeFocused();

  const navigationTarget = await navigation.getByRole("link", { name: "Operations" }).boundingBox();
  expect(navigationTarget?.height).toBeGreaterThanOrEqual(44);
  expect(navigationTarget?.width).toBeGreaterThanOrEqual(44);
});

test("Spanish operations shell keeps landmarks and the plan destination localized", async ({ browser }) => {
  const context = await browser.newContext({ locale: "es-MX" });
  const page = await context.newPage();

  try {
    const response = await page.goto("/");
    expect(response?.status()).toBe(200);
    await expect(page.locator("html")).toHaveAttribute("lang", "es");
    await expect(page.getByRole("navigation", { name: "Navegación principal" })).toBeVisible();
    await expect(page.getByRole("link", { name: "Plan" })).toHaveAttribute("href", "/settings/plan");
    const main = page.getByRole("main", { name: "Espacio de trabajo de operaciones" });
    await expect(main).toBeVisible();
    await page.keyboard.press("Tab");
    await expect(page.getByRole("link", { name: "Saltar al contenido principal" })).toBeFocused();
    await page.keyboard.press("Enter");
    await expect(main).toBeFocused();
  } finally {
    await context.close();
  }
});

test("Plan navigation reaches the unauthenticated safe state instead of an error page", async ({ page }) => {
  await page.goto("/");

  await page.getByRole("link", { name: "Plan" }).click();
  await expect(page).toHaveURL(/\/settings\/plan$/);
  await expect(page.getByRole("heading", { level: 1, name: "Plan and privacy" })).toBeVisible();
  await expect(page.getByRole("alert", { name: "Plan and privacy" })).toContainText("Plan details are temporarily unavailable.");
  await expect(page.getByRole("link", { name: "Retry plan settings" })).toBeVisible();
});
