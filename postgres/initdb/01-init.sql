-- Runs automatically on first postgres container start.
-- CURRENT_USER resolves to POSTGRES_USER from docker-compose env.

CREATE DATABASE langfuse
    WITH OWNER = CURRENT_USER ENCODING = 'UTF8' CONNECTION LIMIT = -1;

CREATE DATABASE litellm
    WITH OWNER = CURRENT_USER ENCODING = 'UTF8' CONNECTION LIMIT = -1;
