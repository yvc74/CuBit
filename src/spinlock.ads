-------------------------------------------------------------------------------
-- CubitOS
-- Copyright (C) 2019 Jon Andrew
--
-- @summary
-- CubitOS Spinlocks
-------------------------------------------------------------------------------
with locks; use locks;
with x86;

package Spinlock with
    SPARK_Mode => On
is
    type SpinLock is private;

    ---------------------------------------------------------------------------
    -- Getter function for lock state. Necessary for SPARK verification,
    --  since contracts can't access the member variable .state of an abstract
    --  state.
    ---------------------------------------------------------------------------
    function isLocked(s : in Spinlock) return Boolean;

    ---------------------------------------------------------------------------
    -- enterCriticalSection tries to acquire a spinlock before returning. 
    -- Disables interrupts, so these need to be set up before attempting to
    -- use a spinlock.
    ---------------------------------------------------------------------------
    procedure enterCriticalSection(s : in out Spinlock) with
        Global => (In_Out => x86.interruptsEnabled),
        Post => isLocked(s);

    ---------------------------------------------------------------------------
    -- exitCriticalSection releases a spinlock. 
    --
    -- Re-enables interrupts if they were enabled prior to a call to
    --  enterCriticalSection. If they weren't, it won't.
    --
    -- It is an error to exitCriticalSection unless we've previously
    --  entered it via enterCriticalSection.
    --
    --  (We don't have an explicit check
    --  for PICInitialized, since we already check for locked, and we can't
    --  lock it without calling enterCriticalSection, which checks for PIC
    --  initialization.)
    ---------------------------------------------------------------------------
    procedure exitCriticalSection(s : in out Spinlock) with
        Global => (In_Out => x86.interruptsEnabled),
        Pre => isLocked(s),
        Post => not isLocked(s);

private
    ---------------------------------------------------------------------------
    -- Structure for basic spinlocks.
    -- @field state - whether this spinlock is currently locked or not.
    --  This is used for formal verification.
    -- @field priorFlags - store the state of the RFLAGS register prior to
    --  entering a critical section using this lock. This is so that if
    --  interrupts were disabled prior to entering the critical section, we
    --  don't blindly re-enable them.
    ---------------------------------------------------------------------------
    type Spinlock is
    record
        state : LockBool := UNLOCKED;
        priorFlags : x86.RFlags;
        -- TODO: add info about who is holding this, maybe nesting depth.
    end record;
end spinlock;