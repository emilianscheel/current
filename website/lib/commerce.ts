export const PURCHASE_AMOUNT = 2000;
export const PURCHASE_CURRENCY = "usd";
export const SOFTWARE_TAX_CODE = "txcd_10202000";

export function inclusiveTaxLine(reference: string) {
  return {
    amount: PURCHASE_AMOUNT,
    quantity: 1,
    reference,
    tax_behavior: "inclusive" as const,
    tax_code: SOFTWARE_TAX_CODE,
  };
}

export function shouldRevokeRefund(amount: number, amountRefunded: number) {
  return amount > 0 && amountRefunded >= amount;
}

export function shouldRevokeDispute(status: string) {
  return status === "lost";
}
