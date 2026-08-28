import { expect, test } from "@playwright/test";

test("serves the Spanish shell when the request prefers Spanish", async ({ browser }) => {
  const spanishContext = await browser.newContext({
    locale: "es-MX",
  });
  const page = await spanishContext.newPage();

  const requestPromise = page.waitForRequest((request) => request.isNavigationRequest());
  const response = await page.goto("/");
  const request = await requestPromise;

  expect(response?.status()).toBe(200);
  expect(request.headers()["accept-language"]).toMatch(/^es-MX/i);
  await expect(page.locator("html")).toHaveAttribute("lang", "es");
  await expect(page.getByRole("navigation", { name: "Navegación principal" })).toBeVisible();
  await expect(page.getByRole("link", { name: "Flota" })).toBeVisible();

  await spanishContext.close();
});

test("keeps every visible English navigation destination available", async ({ page }) => {
  const rootResponse = await page.goto("/", {
    waitUntil: "domcontentloaded",
  });

  expect(rootResponse?.status()).toBe(200);
  await expect(page.locator("html")).toHaveAttribute("lang", "en");

  const navigation = page.getByRole("navigation", { name: "Primary navigation" });
  await expect(navigation.getByRole("link")).toHaveCount(5);
  const hrefs = await navigation.getByRole("link").evaluateAll((links) =>
    links.map((link) => link.getAttribute("href")),
  );

  expect(hrefs).toEqual(["/operations", "/loads", "/drivers", "/vehicles", "/fleet"]);

  for (const href of hrefs) {
    expect(href).not.toBeNull();

    const response = await page.goto(href!, { waitUntil: "domcontentloaded" });
    expect(response?.status()).toBe(200);
    await expect(page.getByRole("main")).toBeVisible();
    await expect(page.getByText("This page could not be found.")).toHaveCount(0);
  }
});
