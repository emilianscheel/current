import { describe, expect, test } from "bun:test";
import {
  inclusiveTaxLine,
  PURCHASE_AMOUNT,
  PURCHASE_CURRENCY,
  shouldRevokeDispute,
  shouldRevokeRefund,
  SOFTWARE_TAX_CODE,
} from "./commerce";

describe("commerce policy", () => {
  test("uses a fixed tax-inclusive downloadable software price", () => {
    expect(PURCHASE_AMOUNT).toBe(2000);
    expect(PURCHASE_CURRENCY).toBe("usd");
    expect(inclusiveTaxLine("ABC-123-XYZ")).toEqual({
      amount: 2000,
      quantity: 1,
      reference: "ABC-123-XYZ",
      tax_behavior: "inclusive",
      tax_code: SOFTWARE_TAX_CODE,
    });
  });

  test("revokes full but not partial refunds", () => {
    expect(shouldRevokeRefund(2000, 2000)).toBeTrue();
    expect(shouldRevokeRefund(2000, 500)).toBeFalse();
  });

  test("revokes only lost disputes", () => {
    expect(shouldRevokeDispute("lost")).toBeTrue();
    expect(shouldRevokeDispute("won")).toBeFalse();
    expect(shouldRevokeDispute("under_review")).toBeFalse();
  });
});
