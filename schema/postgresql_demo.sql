INSERT INTO api_keys(user_id, name, value, status) VALUES((SELECT user_id FROM users LIMIT 1), 'demo', 'C082674C-0218-11E8-90FC-A8C4224AE347', 'active');
