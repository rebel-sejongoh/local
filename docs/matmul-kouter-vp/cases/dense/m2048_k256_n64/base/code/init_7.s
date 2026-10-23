.arch rebel.evt1
.text_ncsu
.target 0x400
.place col=6 line=0
.spr 0xff01ff
SYNC {dir.get=1, dir.put=1, lsync_mask.nclu=1}
RETURN
RETURN
RETURN

.text_nclu
.target 0x200
.place col=7 line=0
.spr 0xff01ff
SYNC {dir.get=1, dir.put=1, lsync_mask.ncsu=1}
MESYNC {dir.get=1, dir.put=1, sync_mask.dnc0=1, sync_mask.nclu=1}
RETURN
RETURN
