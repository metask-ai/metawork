CREATE TABLE messages (
    binding_id BLOB NOT NULL,
    message_id TEXT NOT NULL,
    sent_at_ms INTEGER NOT NULL,
    direction TEXT NOT NULL CHECK (direction IN ('in', 'out', 'self')),
    sender TEXT NOT NULL,
    body TEXT NOT NULL,
    from_agent TEXT,
    recipients TEXT NOT NULL,
    read_receipts TEXT NOT NULL,
    related_ids TEXT NOT NULL,
    first_seen_new INTEGER NOT NULL CHECK (first_seen_new IN (0, 1)),
    PRIMARY KEY (binding_id, message_id)
) STRICT;

CREATE TABLE conversations (
    binding_id BLOB NOT NULL,
    peer_id TEXT NOT NULL,
    display_name TEXT NOT NULL,
    username TEXT,
    latest_id TEXT NOT NULL,
    latest_at_ms INTEGER NOT NULL,
    history_start_id TEXT,
    PRIMARY KEY (binding_id, peer_id),
    FOREIGN KEY (binding_id, peer_id, latest_id)
        REFERENCES conversation_messages DEFERRABLE INITIALLY DEFERRED
) STRICT;

CREATE INDEX conversations_by_activity
    ON conversations(binding_id, latest_at_ms DESC, peer_id);

-- A predecessor is recorded only when a page proves adjacency for this peer.
-- A missing edge is either the known start of history or a gap to fetch.
CREATE TABLE conversation_messages (
    binding_id BLOB NOT NULL,
    peer_id TEXT NOT NULL,
    message_id TEXT NOT NULL,
    previous_id TEXT CHECK (previous_id <> message_id),
    PRIMARY KEY (binding_id, peer_id, message_id),
    FOREIGN KEY (binding_id, peer_id) REFERENCES conversations,
    FOREIGN KEY (binding_id, message_id) REFERENCES messages,
    FOREIGN KEY (binding_id, peer_id, previous_id)
        REFERENCES conversation_messages DEFERRABLE INITIALLY DEFERRED
) STRICT;
