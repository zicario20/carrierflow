import { expect, test } from "@playwright/test";

test("serves the CarrierFlow home page over HTTP", async ({ page }) => {
  const response = await page.goto("/");

  expect(response?.status()).toBe(200);
  await expect(page).toHaveTitle(/CarrierFlow/);
  await expect(page.getByRole("heading", { name: "CarrierFlow" })).toBeVisible();
});
