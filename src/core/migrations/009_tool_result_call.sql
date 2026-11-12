-- The call a tool result answers, and that call's tool.
--
-- Null on every other role, and on results stored before these columns
-- existed; loading pairs those with their calls by order.
ALTER TABLE message ADD COLUMN tool_call_id TEXT;
ALTER TABLE message ADD COLUMN tool_name TEXT;
