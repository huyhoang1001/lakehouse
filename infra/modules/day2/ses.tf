# ses.tf
# -----------------------------------------------------------------------------
# Task 6 — SES email identities used by NT_Accelerate_Send_Mail (Req 11.1).
#
# Both the sender and every receiver must be verified before SES will deliver
# in sandbox mode. Verification is a manual step (click the link in the
# confirmation email); see README.md, "SES Configuration".
# -----------------------------------------------------------------------------

# Task 6.1 — sender identity (Req 11.1).
resource "aws_ses_email_identity" "sender" {
  email = var.ses_sender_email
}

# Task 6.2 — one receiver identity per address (Req 11.1).
resource "aws_ses_email_identity" "receiver" {
  for_each = toset(var.ses_receiver_emails)

  email = each.value
}
