use std::collections::HashSet;
use std::hash::Hash;

pub struct RecentItems<T> {
    set: HashSet<T>,
    buffer: Vec<T>,
    next: usize,
    capacity: usize,
}

impl<T: Eq + Hash + Clone> RecentItems<T> {
    pub fn new(capacity: usize) -> Self {
        RecentItems {
            set: HashSet::with_capacity(capacity),
            buffer: Vec::with_capacity(capacity),
            next: 0,
            capacity,
        }
    }

    /// Attempts to insert `item`.
    ///
    /// Returns `true` if the item was not already present (and was inserted).
    /// Returns `false` if the item was already present (and nothing is changed).
    pub fn push(&mut self, item: T) -> bool {
        // If already seen, do nothing
        if !self.set.insert(item.clone()) {
            return false;
        }

        // New item: we must insert it into the circular buffer,
        // possibly evicting the oldest.
        if self.buffer.len() < self.capacity {
            self.buffer.push(item);
            self.next = self.buffer.len() - 1;
        } else {
            self.next = (self.next + 1) % self.capacity;
            let old = std::mem::replace(&mut self.buffer[self.next], item);
            self.set.remove(&old);
        }
        true
    }
}

