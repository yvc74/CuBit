-------------------------------------------------------------------------------
-- CuBit OS
-- Copyright (C) 2019 Jon Andrew
--
-- @summary Virtual Memory Manager
-------------------------------------------------------------------------------

with Interfaces; use Interfaces;
with BootAllocator;
--with config;
--with Pagetable;
with MemoryAreas; use MemoryAreas;
with Textmode; use Textmode;
--with Util;
--with Virtmem;
with x86;

package body Mem_mgr
    with SPARK_Mode => On
is
    -- raise if we fail to re-map any pages
    RemapException : exception;

    -- Switch from bootstrap page table to the primary kernel page table.
    kernelP4 : aliased Virtmem.P4 with alignment => Virtmem.PAGE_SIZE;



    ---------------------------------------------------------------------------
    -- determineFlagsAndMapPage - given a frame number, map it with the 
    -- appropriate page flags, depending on if it is part of the kernel,
    -- etc.
    ---------------------------------------------------------------------------
    procedure determineFlagsAndMapFrame(frame : in Virtmem.PFN) is

        procedure mapPage is new Virtmem.mapPage(allocate);
        
        ok              : Boolean;

        fromPhys        : constant Virtmem.PhysAddress :=
            Virtmem.PFNToAddr(frame);

        toVirtLinear    : constant Virtmem.VirtAddress :=
            Virtmem.P2V(fromPhys);

        toVirtKernel    : constant Virtmem.VirtAddress :=
            fromPhys + Virtmem.KERNEL_BASE;

    begin
        -- We'll map the kernel sections twice - once to the linear-mapped
        -- region (read-only), and again to the kernel-mapped region
        -- (as code or r/w data).

        if frame in kernelTextPages then
            mapPage(fromPhys, 
                    toVirtLinear,
                    Virtmem.PG_KERNELDATARO,
                    kernelP4,
                    ok);

            if not ok then raise RemapException; end if;

            mapPage(fromPhys,
                    toVirtKernel,
                    Virtmem.PG_KERNELCODE,
                    kernelP4,
                    ok);

            --print(" Mapped kernel .text at ");
            --print(toVirtLinear); print(" and "); println(toVirtKernel);

        elsif frame in kernelROPages then

            mapPage(fromPhys,
                    toVirtLinear,
                    Virtmem.PG_KERNELDATARO,
                    kernelP4,
                    ok);

            if not ok then raise RemapException; end if;

            mapPage(fromPhys,
                    toVirtKernel,
                    Virtmem.PG_KERNELDATARO,
                    kernelP4,
                    ok);

        elsif frame in kernelRWPages then

            mapPage(fromPhys,
                    toVirtLinear,
                    Virtmem.PG_KERNELDATARO,
                    kernelP4,
                    ok);

            if not ok then raise RemapException; end if;
            
            mapPage(fromPhys,
                    toVirtKernel,
                    Virtmem.PG_KERNELDATA,
                    kernelP4,
                    ok);

        else
            -- everything else gets mapped to the linear area
            mapPage(fromPhys,
                    toVirtLinear,
                    Virtmem.PG_KERNELDATA,
                    kernelP4,
                    ok);

        end if;

        if not ok then
            print("ERROR: unable to map page from ");
            print(fromPhys);
            print(" to linear or kernel region.");
            raise RemapException;
        end if;
    end determineFlagsAndMapFrame;


    ---------------------------------------------------------------------------
    -- mapBigFrameAsSmallFrames
    ---------------------------------------------------------------------------
    procedure mapBigFrameAsSmallFrames(bigFrame : in Virtmem.BigPFN) is

        procedure determineFlagsAndMapFrame is new
            Mem_mgr.determineFlagsAndMapFrame(allocate);
    
        use type Virtmem.PFN;

        -- each big PFN contains 512 small frames
        startFrame : constant Virtmem.PFN := Virtmem.bigPFNToPFN(bigFrame);
        endFrame   : constant Virtmem.PFN := startFrame + 511;       
    begin
    
        for frame in startFrame..endFrame loop
            determineFlagsAndMapFrame(frame);
        end loop;
    end mapBigFrameAsSmallFrames;


    ---------------------------------------------------------------------------
    -- mapBigFrame 
    ---------------------------------------------------------------------------
    procedure mapBigFrame(bigFrame : in Virtmem.BigPFN) is

        fromPhys        : constant Virtmem.PhysAddress :=
            Virtmem.BigPFNToAddr(bigFrame);

        toVirtLinear    : constant Virtmem.VirtAddress :=
            Virtmem.P2V(fromPhys);
        
        ok : Boolean;

        procedure mapBigPage is new
            Virtmem.mapBigPage(allocate);
    begin
        -- print(" Mapping bigFrame: "); println(Unsigned_32(bigFrame));
        -- print(" Mapping fromPhys: "); println(fromPhys);
        mapBigPage( fromPhys,
                    toVirtLinear,
                    Virtmem.PG_KERNELDATA,
                    kernelP4,
                    ok);

        if not ok then
            print("ERROR: unable to map big page from ");
            print(fromPhys);
            print(" to linear region.");
            raise RemapException;
        end if;
    end mapBigFrame;


    function isBigFrameAligned(addr : in Virtmem.PhysAddress) 
        return Boolean
    is
    begin
        return Unsigned_64(addr) mod Unsigned_64(Virtmem.BIG_FRAME_SIZE) = 0;
    end isBigFrameAligned;


    ---------------------------------------------------------------------------
    -- mapArea - map a memory area
    -- We assume that memory areas from Multiboot do not overlap.
    ---------------------------------------------------------------------------
    procedure mapArea(area : in MemoryAreas.MemoryArea) is

        use type Virtmem.PFN;
        use type Virtmem.BigPFN;

        procedure mapBigFrame is new 
            Mem_mgr.mapBigFrame(allocate);

        procedure determineFlagsAndMapFrame is new 
            Mem_mgr.determineFlagsAndMapFrame(allocate);

        -- big PFN containing the top of the stack.
        kernelEndBigPFN : constant Virtmem.BigPFN :=
            Virtmem.addrToBigPFN(Virtmem.V2P(Virtmem.STACK_TOP - 1));

        -- frame we are considering mapping
        curFrame        : Virtmem.PFN;

        -- address we are considering mapping
        curAddr         : Virtmem.PhysAddress;

        smallPagesMapped : Natural := 0;
        bigPagesMapped : Natural := 0;
    begin
        --print("Mapping area "); print(area.startAddr); print(" to "); println(area.endAddr);

        -- iterate by small frames, trying to map big pages if we can.
        curFrame := Virtmem.addrToPFN(area.startAddr);

        mapFramesInArea:
        loop
            curAddr := Virtmem.pfnToAddr(curFrame);

            -- If this frame is big-frame aligned, past the kernel, and
            -- there's enough room left in the area to map it as a big
            -- page, do so.
            if  isBigFrameAligned(curAddr) and
                area.endAddr - curAddr >= (Virtmem.BIG_FRAME_SIZE - 1) and
                curAddr >= Virtmem.V2P(Virtmem.STACK_TOP)
            then
                mapBigFrame(Virtmem.pfnToBigPFN(curFrame));
                curFrame := curFrame + 512;
                bigPagesMapped := bigPagesMapped + 1;
            else
                determineFlagsAndMapFrame(curFrame);
                curFrame := curFrame + 1;
                smallPagesMapped := smallPagesMapped + 1;
            end if;

            exit mapFramesInArea when
                curFrame > Virtmem.addrToPFN(area.endAddr);

        end loop mapFramesInArea;

        --print(" Mapped "); print(smallPagesMapped); print(" small pages, and ");
        --print(bigPagesMapped); println(" big pages.");
    end mapArea;


    ---------------------------------------------------------------------------
    -- mapIOArea - map a memory area with PG_IO flags
    ---------------------------------------------------------------------------
    procedure mapIOArea(area : in MemoryAreas.MemoryArea) is

        function mapIOFrame is new Mem_mgr.mapIOFrame(allocate);
    
        ok : Boolean;
    
    begin
        --print(" mapping IO area "); print(area.startAddr); print(" to "); println(area.endAddr);
        for frame in 
            Virtmem.addrToPFN(area.startAddr) .. 
            Virtmem.addrToPFN(area.endAddr) loop

            ok := mapIOFrame(Virtmem.PFNToAddr(frame));

            if not ok then
                raise RemapException with "Unable to map IO area";
            end if;

        end loop;
    end mapIOArea;


    ---------------------------------------------------------------------------
    -- map all physical memory into our p4 table.
    ---------------------------------------------------------------------------
    procedure setupLinearMapping(areas : in MemoryAreas.MemoryAreaArray) with
        SPARK_Mode => Off
    is
        procedure mapIOArea is new Mem_mgr.mapIOArea(BootAllocator.allocFrame);
        procedure mapArea is new Mem_mgr.mapArea(BootAllocator.allocFrame);
    begin

        -- Zeroize the top-level page table
        for i in kernelP4'Range loop
            kernelP4(i) := Virtmem.u64ToPTE(0);
        end loop;

        -- Map everything R/W below 0x100000 (except null page) to start.
        mapArea(MemoryArea'(kind        => MemoryAreas.USABLE,
                            startAddr   => 1,
                            endAddr     => 16#FFFFF#));

        -- Map the rest of our memory areas.
        for area of areas loop
            if area.kind = MemoryAreas.BAD then
                null;
            elsif area.kind = MemoryAreas.VIDEO then
                mapIOArea(area);
            else
                mapArea(area);
            end if;
        end loop;

        -- Make these new page tables the active ones.
        switchAddressSpace;

    end setupLinearMapping;


    ---------------------------------------------------------------------------
    -- switchAddressSpace
    ---------------------------------------------------------------------------
    procedure switchAddressSpace with
        SPARK_Mode => On
    is
    begin
        -- only switch if its necessary to avoid the TLB flush
        if x86.getCR3 /= Virtmem.K2P(To_Integer(kernelP4'Address)) then
            --textmode.print("Switching to Primary Kernel Page Tables at ");
            --textmode.println(Virtmem.K2P(To_Integer(kernelP4'Address)));
            Virtmem.setActiveP4(Virtmem.K2P(To_Integer(kernelP4'Address)));
        end if;
    end switchAddressSpace;


    ---------------------------------------------------------------------------
    -- Map a single frame of memory-mapped IO region into the higher-half
    -- w/ generic procedure "allocate"
    ---------------------------------------------------------------------------
    function mapIOFrame(addr : in Virtmem.PhysAddress) return Boolean
        with SPARK_Mode => On
    is
        procedure mapPage is new Virtmem.mapPage(allocate);
        ok : Boolean;

    begin
        mapPage(addr, virtmem.P2V(addr), virtmem.PG_IO, kernelP4, ok);
        
        if ok then
            Virtmem.flushTLB;
            return True;
        else
            return False;
        end if;

    end mapIOFrame;

end mem_mgr;

-- textmode.print(" Mapping ");
-- textmode.println(" pages");
-- textmode.print("srodata: "); textmode.println(srodataPhys);
-- textmode.print("erodata: "); textmode.println(erodataPhys);
-- textmode.print("sdata: "); textmode.println(sdataPhys);
-- textmode.print("edata: "); textmode.println(edataPhys);
-- textmode.print("sbss: "); textmode.println(sbssPhys);
-- textmode.print("ebss: "); textmode.println(ebssPhys);
-- textmode.print("stext: "); textmode.println(stextPhys);
-- textmode.print("etext: "); textmode.println(etextPhys);
-- textmode.print("stack bottom: "); textmode.println(stackBottomPhys);
-- textmode.print("stack top: "); textmode.println(stackTopPhys);