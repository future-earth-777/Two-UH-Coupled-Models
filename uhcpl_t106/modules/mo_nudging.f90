MODULE mo_nudging

  !======================================================================
  !
  ! J. Feichter    Uni Hamburg    Jan 91 and Apr 93
  ! W. May         DMI-Copenhagen Mar 97
  ! M. Stendel     MPI-Hamburg    Sep 96 and May 97
  ! H.-S. Bauer    MPI-Hamburg    Jul 98
  ! I. Kirchner    MPI-Hamburg    Nov 98 and Oct/Dec 99, March 2000
  ! I. Kirchner    MPI-Hamburg    May 2000
  ! I. Kirchner    MPI-Hamburg    Sep 2000
  ! I. Kirchner    IfM FU Berlin  Sep 2005 parallel nudging
  !
  ! ****************** Interface to ECHAM4 ******************************
  !
  ! *ECHAM*    *NUDGING*
  !
  ! *** initialization
  !
  ! INICTL ---> NudgingInit(NDG_INI_TIME)
  ! CONTROL --> NudgingInit(NDG_INI_MEM)
  !
  ! *** run time interface
  !
  ! STEPON ---> NudgingReadSST                read new sst field
  !         |
  !         +-> Nudging                       perform nudging
  !         |   +--->GetNudgeData             read nudging data sets
  !         |         +-->ReadOneBlock        read one data time step
  !         |              +-->OpenOneBlock   open new data block
  !         |              +-->CloseBlock     close data block
  !         |
  !         +-> NudgingOut                    store nudging terms (accu+inst)
  !         |   +-->NudgingStoreSP            store one spectral array
  !         |
  !         +-> NudgingRerun(NDG_RERUN_WR)    read/write nudging buffer
  !
  ! GPC ------> NudgingSSTnew                 reset sst at latitude circle
  !
  !======================================================================
  ! 
  !   Following Krishnamurti et al. (1991), Tellus 43AB, 53-81.
  !   
  !   This is "pure" Krishnamurti, which means that there are no other
  !   relaxation terms on rhs!
  !
  !   (Eq. 7.3): A(t+dt) = (A (t+dt) +2dt*N * A (t+dt)) / (1+2dt*N),
  !                          *                 0
  ! 
  !   where  A (t+dt) is a predicted value of A (t+dt) prior to nudging.
  !           *
  !          A (t+dt) is a future value which the nudging is aimed at.
  !           0            (in the twin case that is the observed value
  !                         at the later time)
  !          N is nudging coefficient
  !
  ! the implementation of the method is modified (I.Kirchner)
  !
  ! NEW = A*OLD + B*OBS
  !
  ! implicit -->  A = 1/(1-2*dt*N)  B = 2*dt*N/(1-2*dt*N)
  !
  ! explicit -->  A = 1 - 2*dt*N    B = 2*dt*N
  !
  ! --------------------------------------------------------------------

  USE mo_kind,          ONLY: cp
  USE mo_exception,     ONLY: finish, message
  USE mo_doctor,        ONLY: nout, nin
  USE mo_start_dataset, ONLY: lres, nstart, nstep, ly365
  USE mo_memory_g3a,    ONLY: auxil1m, auxil2m, tsm, tsm1m, slmm, seaicem
  USE mo_memory_g3b,    ONLY: seaice
  USE mo_memory_sp,     ONLY: sd, svo, stp
  USE mo_nmi,           ONLY: NMI_Make, NMI_MAKE_FMMO, NMI_MAKE_FOD
  USE mo_year,          ONLY: iymd2c, cd2dat, ic2ymd, isec2hms, im2day
  USE mo_physc2,        ONLY: ctfreez
  USE mo_constants,     ONLY: dayl
  USE mo_truncation,    ONLY: nmp, nnp
  USE mo_control,       ONLY: nlon, nlev, nsp, nlevp1, ncbase, nm, &
&         ntbase, dtime, twodt, nresum, ngl, lnudge, ltdiag, nmp1, nn, &
&         ncdata, ntdata, lnmi, nrow, n2sp, nptime, vct, lamip2, nnp1, lptime, lcouple

  USE mo_post,          ONLY: nunitsp, nunitdf, lppt, lppp, lppvo, lppd
  USE mo_grib,          ONLY: kgrib, kleng, klengo, ksec0, ksec1, ksec2_sp, psec2, ksec3, psec3, &
&         ksec4, kword, nbit, iobyte, nudging_table, year, month, day, hour, minute, century, &
&         code_parameter, level_type, level_p2, set_output_time, local_table
  USE mo_mpi

  USE mo_time_control

  USE mo_diag_tendency, ONLY: ndvor, nddiv, ndtem, ndprs, pdvor, pddiv, pdtem, pdprs, ipdoaccu

  USE mo_nudging_buffer

  USE mo_decomposition, ONLY: local_decomposition, global_decomposition
  USE mo_transpose,     ONLY: gather_gp, scatter_gp, gather_sp, scatter_sp

  IMPLICIT NONE

  PUBLIC  :: NudgingInit
  PUBLIC  :: Nudging

  PRIVATE :: GetNudgeData
  PRIVATE :: ReadOneBlock
  PRIVATE :: OpenOneBlock
  PRIVATE :: CloseBlock

  PUBLIC  :: NudgingReadSST
  PUBLIC  :: NudgingSSTnew

  PUBLIC  :: NudgingOut
  PUBLIC  :: NudgingRerun


  INTEGER, PARAMETER :: NDG_INI_TIME = 0
  INTEGER, PARAMETER :: NDG_INI_MEM  = 1

  INTEGER, PARAMETER :: NDG_RERUN_WR = -1
  INTEGER, PARAMETER :: NDG_RERUN_RD =  1

  CHARACTER(256)     :: ndg_mess

  LOGICAL :: lnudgdbx = .FALSE.
  ! true  -> additional debugging messages

  LOGICAL :: lnudgini = .FALSE.
  ! true  --> use first date from nudging data block
  ! false --> use information from history data (default)

  LOGICAL :: lnudgimp = .TRUE.
  ! true  --> implicit nudging (default)
  ! false --> explicit nudging

  LOGICAL :: lnudgpat = .FALSE.
  ! true  --> assimilation of correlation pattern
  ! false --> no effect (default)

  LOGICAL :: lnudgcli = .FALSE.
  ! true  --> year ignored, only month/day/time important for synchronization
  ! false --> read data continuously (default)

  INTEGER :: ileap = 0   ! correction of time steps in climate mode for leap years

  LOGICAL :: lnudgfrd = .FALSE.
  ! true  --> NMI filter performed in ReadOneBlock
  ! false --> NMI filter after time interpolation (default)

  LOGICAL :: lnudgwobs = .FALSE.
  ! true  --> store reference data in model output

  LOGICAL :: lsite = .FALSE.
  ! true  --> calculates additional SITE (systematic initial tendency errors)

  LOGICAL :: ldamplin = .TRUE.
  ! true  --> linear damping between two nudging times (default)
  ! false --> non-linear damping

  LOGICAL :: ltintlin = .TRUE.
  ! true  --> linear time interpolation (default)
  ! false --> non-linear time interpolation

  ! external nudging weigths [1.e-5/sec]
  INTEGER, PARAMETER :: nmaxc = 50

  ! set nudging coefficients to standard (Jeuken et al. 1996)
  !REAL               :: nudgd(nmaxc) =  5.0 !  5.56 hours
  !REAL               :: nudgv(nmaxc) = 10.0 !  2.78 hours
  !REAL               :: nudgt(nmaxc) =  1.0 ! 27.8 hours
  !REAL               :: nudgp        = 10.0 !  2.78 hours

! set nudging coefficients following DMI (default)
!fu++ 20090820_test
!  REAL               :: nudgd(nmaxc) =  0.579 ! 48 hours
!  REAL               :: nudgv(nmaxc) =  4.63  !  6 hours
!  REAL               :: nudgt(nmaxc) =  1.16  ! 24 hours
!  REAL               :: nudgp        =  1.16  ! 24 hours
!
!fu++ 20090820_test(BEST options !!)
!  REAL               :: nudgd(nmaxc) =  5.  ! 5.56 hours
!  REAL               :: nudgv(nmaxc) =  5.  ! 5.56 hours
!  REAL               :: nudgt(nmaxc) =  5.  ! 5.56 hours
!  REAL               :: nudgp        =  5.  ! 5.56 hours
!
!fu++ 03/31/2010 
  REAL               :: nudgd(nmaxc) =  10.  ! 2.78 hours
  REAL               :: nudgv(nmaxc) =  10.  ! 2.78 hours
  REAL               :: nudgt(nmaxc) =  10.  ! 2.78 hours
  REAL               :: nudgp        =  10.  ! 2.78 hours
!
!test on 03/09/2010
!recover on 03/10/2010
!
  REAL, PARAMETER :: nfact=1.e-5  ! rescaling factor for nudging coefficients
  ! internal weights for observed data, rescaled [1/sec]
  REAL, POINTER, DIMENSION(:) :: nudgdo, nudgvo, nudgto
  REAL                        :: nudgpo
  ! local fields with nudging coefficients, size = (spectral X level)
  REAL, POINTER, DIMENSION(:,:,:) :: nudgda, nudgdb, nudgva, nudgvb, nudgta, nudgtb

  ! boundaries of nudging window
!fu++ oct/22/2010  INTEGER :: nudgsmin = 0  ! skip global average
  INTEGER :: nudgsmin = -1  ! include global average

  INTEGER :: nudgsmax
  ! nudgsmin  -1 .......... incl. global mean
  !            0 ... nmp1-1 zonal wavenumber
  INTEGER :: nudglmin = 1
  INTEGER :: nudglmax
  INTEGER :: nudgmin, nudgmax

  ! reduce nudging weight between the reference date/time (0...1)
  REAL    :: nudgdamp = 1.0  ! no weigthing between two time steps

  ! influence radius near nudging times
  REAL    :: nudgdsize = 0.5 ! nudging all steps between reference dates 

  ! specific truncation of spectral coefficients used
  INTEGER, PARAMETER :: NDG_WINDOW_ALL  = 0
  INTEGER, PARAMETER :: NDG_WINDOW_CUT  = 1
  INTEGER, PARAMETER :: NDG_WINDOW_CUT0 = 2
  INTEGER :: nudgtrun = NDG_WINDOW_ALL  ! use all zonal indexes
  ! 0 ... use all coefficients of active wave no.
  ! 1 ... cut off meridional index higher than wave no. limit all waves
  ! 2 ... cut off except wave 0

  ! internal flag field
  REAL, POINTER, DIMENSION(:,:,:) :: &
&       flagn, & ! set to 1 inside the nudging region
&       flago, & ! set to 1 outside nudging region
&       flagn_global, flago_global

  ! input/output channels
  INTEGER :: ndunit(18) = (/ &
       81, 82, 83, &
       84, 85, 86, &
       87, 88, 89, &
       46, 47, 48,   40,   99, &
       -1, -1, -1, -1 /)
  !           div vor temP sst
  ! block1 =>  1   2   3   10
  ! block2 =>  4   5   6   11
  ! block3 =>  7   8   9   12
  ! restart file  =>           13
  ! correlation results =>     14
  ! actual block 15(d) 16(v) 17(t) 18(sst) 

  ! internal file pointer of nudging data blocks and sst fields
  !               DIV,    VOR,    TEM+P,  SST,    RERUN
  INTEGER (cp) :: kfiled, kfilev, kfilet, kfiles, kfiler

  INTEGER      :: ndgblock =  1 ! block pointer nudging data
  INTEGER      :: sstblock = -1 ! number of sst file

  CHARACTER(10):: cfile     ! local file name

  ! time/date marker
  ! set pointer in nudging data pool
  ! start at the beginning in the first assigned block and
  ! scann all blocks until the right time window is found
  INTEGER           :: sheadd, sheadt                ! present date/time
  LOGICAL           :: lndgstep0 = .FALSE.
  INTEGER           :: ndgstep0, ihead0d = 0, ihead0t = 0 ! idx YYYYMMDD HHmmss
  LOGICAL           :: lndgstep1 = .FALSE.
  INTEGER           :: ndgstep1, ihead1d = 0, ihead1t = 0 ! idx YYYYMMDD HHmmss
  LOGICAL           :: lndgstep2 = .FALSE.
  INTEGER           :: ndgstep2, ihead2d = 0, ihead2t = 0 ! idx YYYYMMDD HHmmss
  LOGICAL           :: lndgstep3 = .FALSE.
  INTEGER           :: ndgstep3, ihead3d = 0, ihead3t = 0 ! idx YYYYMMDD HHmmss

  ! select the data amount in nudging file using
  !
  LOGICAL    :: linp_vor ! read vorticity
  LOGICAL    :: linp_div ! read divergence
  LOGICAL    :: linp_tem ! read temperatur
  LOGICAL    :: linp_lnp ! read pressure
  INTEGER    :: ilev_v_min, ilev_v_max  ! level selection vorticty
  INTEGER    :: ilev_d_min, ilev_d_max  ! level selection divergence
  INTEGER    :: ilev_t_min, ilev_t_max  ! level selection temperature
  INTEGER    :: ino_v_lev  ! number of input level
  INTEGER    :: ino_d_lev
  INTEGER    :: ino_t_lev  ! last level is for pressure

  ! fields with constant part of pattern correlation (LEVEL,2)
  REAL, POINTER, DIMENSION (:,:) :: a_pat_vor, b_pat_vor, a_nrm_vor
  REAL, POINTER, DIMENSION (:,:) :: a_pat_div, b_pat_div, a_nrm_div
  REAL, POINTER, DIMENSION (:,:) :: a_pat_tem, b_pat_tem, a_nrm_tem
  REAL, POINTER, DIMENSION   (:) :: a_pat_lnp, b_pat_lnp, a_nrm_lnp

  ! sst data usage
  INTEGER, SAVE :: nsstinc = 24       ! sst data given at every 24 hour
  INTEGER, SAVE :: nsstoff = 12       ! 12 UTC sst data used
  INTEGER, SAVE :: ipos
  LOGICAL           :: lsstn      ! true if new sst neccessary
  INTEGER           :: iheads     ! YYYYMMDDHH sst time step
  REAL, POINTER, DIMENSION (:,:) :: sstn  ! (nlon,ngl)

                                  ! correction of freezing point
                                  ! with ERA15  -1.5 recommended
  REAL              :: ndg_freez = 271.65  ! set for ERA15

  ! additional fields (model output)
  ! (A) first set:  nudging term
  ! (B) second set: difference to observations outside the nudging range
  ! (C) third set:  observations instantaneous
  ! (D) : fast mode tendency error
  ! (E) : resuide correction ter
  ! (F) : systematic initial tendency errors accumulated
  !
  ! code numbers :                   Pins,Tins,Dins,Vins,Pacc,Tacc,Dacc,Vacc
! this is for GRIB1 special code page usage
!  INTEGER, PARAMETER :: ndgcode(24)=(/129, 130, 131, 132, 133, 134, 135, 136, &
!&                                     137, 138, 139, 140, 141, 142, 143, 144,&
!&                                     145, 146, 147, 148/)
  INTEGER, PARAMETER :: ndgcode(32)=(/111, 112, 113, 114, 115, 116, 117, 118, &! (A)
&                                      21,  22,  23,  24,  25,  26,  27,  28, &! (B)
&                                      31,  32,  33,  34,                     &! (C)
&                                      35,  36,  37,  38,                     &! (D)
&                                      14,  15,  16,  17,                     &! (E)
&                                     121, 122, 123, 124/)                     ! (F)
  ! last four numbers for fast mode part

  ! nudging tendencies (instantaneous and accumulated)  
  REAL, POINTER, DIMENSION(:,:,:) :: sdten, svten, stten, sdtac, svtac, sttac

  ! accumualted systematic initial tendency errors
  REAL, POINTER, DIMENSION(:,:,:) :: sdsite, svsite, stsite

  ! counter for accumulation
  INTEGER :: iaccu = 0

  INTEGER :: isiteaccu = 0
  LOGICAL :: lsite_n0 = .FALSE.
  LOGICAL :: lsite_n1 = .FALSE.

  CHARACTER(4) :: ndgfmt = 'cray'
  LOGICAL      :: ndgswap = .FALSE.
!#ifdef LINUX
  PUBLIC :: swap32
  INTERFACE swap32
     MODULE PROCEDURE r_swap32
     MODULE PROCEDURE i_swap32
     MODULE PROCEDURE c_swap32
  END INTERFACE
!#endif

  LOGICAL :: ioflag      ! control io for multiprocessing

  ! controls the nudging period
  ! default is no check, all the time you will nudge
  INTEGER :: nudg_start = -1 ! YYYYMMDD
  INTEGER :: nudg_stop  = -1 ! YYYYMMDD
  LOGICAL :: lnudg_do = .TRUE.

CONTAINS
!======================================================================

  SUBROUTINE NudgingInit(itype)
    ! setup nudging parameter and fields

    INCLUDE 'ndgctl.inc'

    INTEGER  :: i, kret, iday, id, im, iy, isec, ihms
    INTEGER  :: ihead(8), itype, is1, is2, jm, ii, sum1, sum2, sum3
    INTEGER  :: icent_ndg, ncbase_ndg, ntbase_ndg

    CHARACTER (8) :: yhead(8)

   ! Intrinsic functions
   INTRINSIC MOD, MAX, MIN

   ioflag = (p_parallel .AND. p_parallel_io) .OR. (.NOT.p_parallel)
 
   IF (ioflag) CALL message('NudgingInit','***** start *****')

   IF (lnudge) THEN

!-- A. nudging
       SELECT CASE(itype)

!-- 1. namelist setup and time adjustment

       CASE(NDG_INI_TIME)            ! read namelist and set time syncronization

          IF (ioflag) CALL message('',' Version 3.23pat 13-SEP-2000 (kirchner@dkrz.de)')
          !--------------------------------------------------------------------
          ! preset variables

          ! nudging options, default settings
          nudgsmax = nn       ! all wave numbers used
          nudglmax = nlev     ! to bottom

          IF (nlev > nmaxc) CALL finish('NudgingInit','number of levels too large')

          ! allocate weights of observations
          ALLOCATE(nudgdo(nlev)); nudgdo(:) = 0.0
          ALLOCATE(nudgvo(nlev)); nudgvo(:) = 0.0
          ALLOCATE(nudgto(nlev)); nudgto(:) = 0.0
          nudgpo    = 0.0

          !----------------------------------------------------------------
          ! read nudging namelist
          IF (ioflag) READ (nin,ndgctl)
          IF (p_parallel) THEN
             CALL p_bcast ( lnudgdbx, p_io)
             CALL p_bcast ( lnudgini, p_io)
             CALL p_bcast ( lnudgimp, p_io)
             CALL p_bcast ( lnudgpat, p_io)
             CALL p_bcast ( lnudgcli, p_io)
             CALL p_bcast ( lnudgfrd, p_io)
             CALL p_bcast ( lsite, p_io)
             CALL p_bcast ( lnudgwobs, p_io)
             CALL p_bcast ( ldamplin, p_io)
             CALL p_bcast ( ltintlin, p_io)
             CALL p_bcast ( nudgd, p_io)
             CALL p_bcast ( nudgv, p_io)
             CALL p_bcast ( nudgt, p_io)
             CALL p_bcast ( nudgp, p_io)
             CALL p_bcast ( nudgdamp, p_io)
             CALL p_bcast ( nudgdsize, p_io)
             CALL p_bcast ( nudgtrun, p_io)
             CALL p_bcast ( nudgsmin, p_io)
             CALL p_bcast ( nudgsmax, p_io)
             CALL p_bcast ( nudglmin, p_io)
             CALL p_bcast ( nudglmax, p_io)
             CALL p_bcast ( nudg_start, p_io)
             CALL p_bcast ( nudg_stop, p_io)
             CALL p_bcast ( nsstinc, p_io)
             CALL p_bcast ( nsstoff, p_io)
             CALL p_bcast ( ndg_freez, p_io)
             CALL p_bcast ( ndgfmt, p_io)
             CALL p_bcast ( ndgswap, p_io)
             CALL p_bcast ( ndunit, p_io)
          END IF

          lnudgdbx = lnudgdbx .AND. ioflag

          IF (lnudgdbx) THEN
             SELECT CASE(ndgfmt)
             CASE('cray')
                WRITE(ndg_mess,*) 'input format is CRAY'
             CASE('ieee')
                WRITE(ndg_mess,*) 'input format is IEEE'
             CASE DEFAULT
                WRITE(ndg_mess,*) 'input format >>',ndgfmt,'<<is not defined'
                CALL finish('NudgingInit',ndg_mess)
             END SELECT
             CALL message('',ndg_mess)

             IF (ndgswap) THEN
                WRITE(ndg_mess,*) 'swap byte order of input data'
             ELSE
                WRITE(ndg_mess,*) 'use input data in original byte order'
             END IF
             CALL message('',ndg_mess)

             WRITE(ndg_mess,*) 'data block 1 units ',(ndunit(i),i= 1, 3),' sst-unit ',ndunit(10)
             CALL message('',ndg_mess)
             WRITE(ndg_mess,*) 'data block 2 units ',(ndunit(i),i= 4, 6),' sst-unit ',ndunit(11)
             CALL message('',ndg_mess)
             WRITE(ndg_mess,*) 'data block 3 units ',(ndunit(i),i= 7, 9),' sst-unit ',ndunit(12)
             CALL message('',ndg_mess)
             WRITE(ndg_mess,*) 'restart file      unit  ', ndunit(13)
             CALL message('',ndg_mess)
          END IF

          IF (ltdiag) THEN
             WRITE(ndg_mess,*) 'correlation file      unit  ', ndunit(14)
             CALL message('',ndg_mess)
             WRITE(cfile,'(a5,i2.2)') 'fort.',ndunit(14)
             OPEN(unit=ndunit(14),file=cfile,form='formatted')
             WRITE(ndunit(14),'(a)') '### start new months ... tendency correlation'
          END IF
          CALL message('','')

          !----------------------------------------------------------------
          ! correct nudging namelist parameters

          IF (.NOT.lres) lnudgini = .TRUE.

          ! nsstinc equals 0 means no external sst is used
          nsstinc = MAX(MIN(nsstinc,24),0)
          nsstoff = MAX(MIN(nsstoff,23),0)
          IF (ndg_freez < 0) THEN
             IF (lnudgdbx) CALL message('','Warning ... external defined CTFREEZ not correct')
             ndg_freez = 271.65
          END IF

          ! correction for pattern assimilation
          IF (lnudgpat)  lnudgimp = .FALSE. ! use explicit method

          IF ( (nudg_start > 0) .AND. (nudg_stop > 0) .AND. (nudg_stop < nudg_start)) THEN
             IF (ioflag) THEN
                WRITE(ndg_mess,*) '  Start nudging at (YYYYMMDD) = ',nudg_start
                CALL message('NudgingInit',ndg_mess)
                WRITE(ndg_mess,*) '  Stop nudging at (YYYYMMDD) = ',nudg_stop
                CALL message('NudgingInit',ndg_mess)
             END IF
             CALL finish('NudginInit','ERROR nudg_stop < nudg_start')
          END IF

          IF (lnudgdbx) THEN
             WRITE(ndg_mess,*) 'Nudging options:'
             CALL message('',ndg_mess)
             IF (lnudgpat) THEN
                WRITE(ndg_mess,*) '  pattern assimilation            LNUDGPAT  = ',lnudgpat
                CALL message('',ndg_mess)
             END IF

             IF ( (nudg_start < 0) .AND. (nudg_stop < 0) ) THEN
                WRITE(ndg_mess,*) '  nudging all times '
             ELSE IF (nudg_start > 0) THEN
                WRITE(ndg_mess,*) '  Start nudging at (YYYYMMDD) = ',nudg_start
             END IF
             CALL message('',ndg_mess)
             IF ( nudg_stop > 0 ) THEN
                WRITE(ndg_mess,*) '  Stop nudging at (YYYYMMDD) = ',nudg_stop
                CALL message('',ndg_mess)
             END IF
                
             WRITE(ndg_mess,*) '  adjust date/time (block 2 used) LNUDGINI  = ',lnudgini
             CALL message('',ndg_mess)
             WRITE(ndg_mess,*) '  implicit method                 LNUDGIMP  = ',lnudgimp
             CALL message('',ndg_mess)
             WRITE(ndg_mess,*) '  debbugging                      LNUDGDBX  = ',lnudgdbx
             CALL message('',ndg_mess)
             WRITE(ndg_mess,*) '  store reference data in output  LNUDGWOBS = ',lnudgwobs
             CALL message('',ndg_mess)
             WRITE(ndg_mess,*) '  calculates SITE                 LSITE     = ',lsite
             CALL message('',ndg_mess)
             WRITE(ndg_mess,*) '  linear time interpolation       LTINTLIN  = ',ltintlin
             CALL message('',ndg_mess)
             WRITE(ndg_mess,*) '  linear damping in time          LDAMPLIN  = ',ldamplin
             CALL message('',ndg_mess)
          END IF

          nudgdamp = MIN(MAX(nudgdamp,0.0),1.0)

          IF (lnudgdbx) THEN
             WRITE(ndg_mess,*) '  reduce damping between reference times ',nudgdamp,' (fraction)'
             CALL message('',ndg_mess)
          END IF
          nudgdsize = MIN(MAX(nudgdsize,0.0),0.5)

          IF (lnudgdbx) THEN
             WRITE(ndg_mess,*) '  damping radius ',nudgdsize
             CALL message('',ndg_mess)
          END IF

          !----------------------------------------------------------------
          ! synchronize date and time
          IF (lnudgini) THEN
             IF (ioflag) THEN
                WRITE(ndg_mess,*) 'Time adjustment'
                CALL message('',ndg_mess)

                IF (ltintlin) THEN
                   ! read first time step of nudging data block 1
                   WRITE(cfile,'(a5,i2.2)') 'fort.',ndunit(1)
                ELSE
                   ! read first time step of nudging data block 2
                   WRITE(cfile,'(a5,i2.2)') 'fort.',ndunit(4)
                END IF
                SELECT CASE(ndgfmt)
                CASE('cray')
                   CALL pbopen(kfiled,cfile,'r',kret)
                   CALL cpbread(kfiled,yhead,8*8,kret)
                   CALL util_i8toi4 (yhead(1), ihead(1),8)
                   CALL pbclose(kfiled,kret)
                CASE('ieee')
                   OPEN(unit=ndunit(4),file=cfile,iostat=kret,action='read',form='unformatted')
                   READ(unit=ndunit(4),iostat=kret) ihead
                   CLOSE(unit=ndunit(4),iostat=kret)
                END SELECT
             END IF
             IF (p_parallel) CALL p_bcast (ihead, p_io)

             ! read date/time information
             ! YYYYMMDD ihead(3), HH ihead(4)
             icent_ndg  = ihead(3)/1000000 + 1
             ncbase_ndg = iymd2c(ihead(3))
             ntbase_ndg = ihead(4)*3600 - (nstep+1)*dtime

             ! adjust model to the nudging data time information
             IF (lnudgdbx) THEN
                WRITE(ndg_mess,'(a,i8,a,i8,a,i10)')&
&                  '   found  NCBASE= ',ncbase,' NTBASE= ',ntbase,' NSTEP= ',nstep
                CALL message('',ndg_mess)
             END IF
             DO
                IF(ntbase_ndg >= 0) EXIT
                ntbase_ndg = ntbase_ndg + dayl
                ncbase_ndg = ncbase_ndg - 1
             END DO
             IF (ncbase < 1) CALL finish('NudgingInit','problem with date/time adjustment')
             ntbase = ntbase_ndg; ntdata = ntbase
             ncbase = ncbase_ndg; ncdata = ncbase

             IF (lnudgdbx) THEN
                WRITE(ndg_mess,'(a,i8,a,i8,a,i10)')&
&                  '   reset  NCBASE= ',ncbase,' NTBASE= ',ntbase,' NSTEP= ',nstep
                CALL message('',ndg_mess)
             END IF

             CALL cd2dat(ncbase,id,im,iy)
             ihms = isec2hms(ntbase)
             IF (lnudgdbx) THEN
                WRITE(ndg_mess,'(a,i4.4,a,i2.2,a,i2.2,a,i6.6)')&
&                  '   new initial date Year ',iy,' Month ',im,' Day ',id,' HHMMSS ',ihms
                CALL message('',ndg_mess)
             END IF

             iday = ncbase + (ntbase+dtime*(nstep+1))/dayl + 0.01
             isec = MOD( (ntbase+dtime*(nstep+1)),dayl)
             CALL cd2dat(iday,id,im,iy)
             ihms = isec2hms(isec)

             IF (lnudgdbx) THEN
                WRITE(ndg_mess,'(a,i4.4,a,i2.2,a,i2.2,a,i6.6)')&
&                  '   start nudging at Year ',iy,' Month ',im,' Day ',id,' HHMMSS ',ihms
                CALL message('',ndg_mess)
             END IF
          END IF

          IF (ioflag) CALL message('NudgingInit','****** basic initialization done *****')

          IF(p_parallel) THEN
             IF(lnudgpat) &
               CALL finish('NudgingInit','pattern nudging works not in parallel mode')
             IF(lnudgcli) &
               CALL finish('NudgingInit','nudging data climate mode works not in parallel mode')
             IF(lsite) &
               CALL finish('NudgingInit','SITE detection works not in parallel mode')
          END IF

!-- 2. Setup nudging coefficients and work space

       CASE(NDG_INI_MEM)

          ! initialize sst memory
          IF (nsstinc==0) THEN
             IF (lnudgdbx) CALL message('',' use standard ECHAM SST')
          ELSE
!fu++ 8/31/2009 from Baoqiang
             ALLOCATE (sstn(local_decomposition%nlon,local_decomposition%nlat))
!new             ALLOCATE (sstn(local_decomposition%nlon,local_decomposition%ngl))
             IF (lnudgdbx) THEN
                CALL message('',' nudging SST memory initialized, use external SST')
                WRITE(ndg_mess,*) '  use new sea ice detection limit NDG_FREEZ = ',ndg_freez
                CALL message('',ndg_mess)
             END IF
          ENDIF

          IF (lnudgdbx) THEN
             WRITE(ndg_mess,*) 'Nudging window options:'
             CALL message('',ndg_mess)
          END IF

          ! ***** setup spectral window for nudging
          nudgsmin = MIN(MAX(nudgsmin,-1),nm)
          nudgsmax = MIN(MAX(nudgsmax, 0),nm)
          nudgsmax = MAX(nudgsmax,nudgsmin)
          IF (lnudgdbx) THEN
             WRITE(ndg_mess,*)&
&               '  modified wavenumber(s) ',nudgsmin,' ... ',nudgsmax
             CALL message('',ndg_mess)
          END IF
          IF (nudgsmin<0) THEN
             IF (lnudgdbx) CALL message('','     global average included')
             nudgmin  = 1
             nudgsmin = 0
          ELSE IF (nudgsmin == 0) THEN
             IF (lnudgdbx) CALL message('','     global average NOT included')
             nudgmin = 2
          ELSE
             nudgmin = nmp(nudgsmin+1)+1
          ENDIF
          nudgmax = nmp(nudgsmax+1)+nnp(nudgsmax+1)
          nudgmax = MAX(nudgmax,nudgmin)
          IF (lnudgdbx) THEN
             WRITE(ndg_mess,*) '  modified spectral index SPECC = ',nudgmin, ' ... ',nudgmax
             CALL message('',ndg_mess)
          END IF

          ! ***** setup level window for nudging
          nudglmin = MIN(MAX(nudglmin,1),nlev)
          nudglmax = MIN(MAX(nudglmax,1),nlev)
          nudglmax = MAX(nudglmax,nudglmin)

          ! ***** setup nudging flag field
          nudgtrun = MAX(MIN(nudgtrun,2),0)

          ALLOCATE (flagn(nlevp1,2,local_decomposition%snsp))
          ALLOCATE (flago(nlevp1,2,local_decomposition%snsp))

          IF ( ioflag ) THEN

             ALLOCATE (flagn_global(nlevp1,2,nsp)); flagn_global(:,:,:) = 0
             ALLOCATE (flago_global(nlevp1,2,nsp)); flago_global(:,:,:) = 1

             SELECT CASE(nudgtrun)
             CASE (NDG_WINDOW_ALL)
                WRITE(ndg_mess,*) '  truncation (',nudgtrun,') ... use all meridional parts'
                flagn_global(nudglmin:nudglmax,:,nudgmin:nudgmax) = 1
                flagn_global(nlevp1           ,:,nudgmin:nudgmax) = 1
                flago_global(nudglmin:nudglmax,:,nudgmin:nudgmax) = 0
                flago_global(nlevp1           ,:,nudgmin:nudgmax) = 0
             CASE (NDG_WINDOW_CUT)
                WRITE(ndg_mess,*) '  truncation (',nudgtrun,')... cut off meridional parts'
                DO jm=nudgsmin,nudgsmax
                   is1 = nmp(jm+1) + 1
                   is2 = nmp(jm+1) + 1 + nudgsmax - jm
                   flagn_global(nudglmin:nudglmax,:,is1:is2) = 1
                   flagn_global(nlevp1           ,:,is1:is2) = 1
                   flago_global(nudglmin:nudglmax,:,is1:is2) = 0
                   flago_global(nlevp1           ,:,is1:is2) = 0
                END DO
             CASE (NDG_WINDOW_CUT0)
                WRITE(ndg_mess,*) '  truncation (',nudgtrun,')... cut off except wave 0'
                DO jm=nudgsmin,nudgsmax
                   IF (jm==0) THEN
                      is1 = nmp(1) + 1
                      is2 = nmp(1) + nnp(1)
                   ELSE
                      is1 = nmp(jm+1) + 1
                      is2 = nmp(jm+1) + 1 + nudgsmax - jm
                   END IF
                   flagn_global(nudglmin:nudglmax,:,is1:is2) = 1
                   flagn_global(nlevp1           ,:,is1:is2) = 1
                   flago_global(nudglmin:nudglmax,:,is1:is2) = 0
                   flago_global(nlevp1           ,:,is1:is2) = 0
                END DO
             END SELECT
             CALL message('',ndg_mess)
             WRITE(ndg_mess,*) '      [',NDG_WINDOW_ALL,' ... all meridional parts used]'
             CALL message('',ndg_mess)
             WRITE(ndg_mess,*) '      [',NDG_WINDOW_CUT,' ... triangular cut-off]'
             CALL message('',ndg_mess)
             WRITE(ndg_mess,*) '      [',NDG_WINDOW_CUT0,' ... triangular cut-off except wave 0]'
             CALL message('',ndg_mess)

             ! check flag field
             sum1 = 0; sum2 = 0; sum3 = 0
             DO i=1,nlevp1
                DO ii=1,nsp
                   sum1 = sum1 + flagn_global(i,1,ii)+flagn_global(i,2,ii)
                   sum2 = sum2 + flago_global(i,1,ii)+flago_global(i,2,ii)
                   sum3 = sum3 + flagn_global(i,1,ii)*flago_global(i,1,ii) &
                        +flagn_global(i,2,ii)*flago_global(i,2,ii)
                END DO
             END DO
             IF ((sum1+sum2)/=(n2sp*nlevp1)) THEN
                WRITE(ndg_mess,*) ' FLAGN= ',sum1,' FLAGO= ',sum2,' O*N= ',sum3,' NO= ',n2sp*nlevp1
                CALL message('',ndg_mess)
                CALL finish('NudgingInit','ERROR nudging flag field mismatch')
             END IF
             CALL message('','')

          END IF

          CALL scatter_sp(flagn_global,flagn,global_decomposition)
          CALL scatter_sp(flago_global,flago,global_decomposition)

          IF (ioflag)  DEALLOCATE(flagn_global, flago_global)


          ! ***** define the external data amount
          ! negative values of nudging coefficients means no data in nudging file

          linp_vor = .FALSE.
          linp_div = .FALSE.
          linp_tem = .FALSE.
          linp_lnp = .FALSE.

          ! initialize upper bound
          ilev_v_max = 0
          ilev_d_max = 0
          ilev_t_max = 0

          ! find maximum level
          DO i = 1,nlev
             IF (nudgv(i) >= 0.) THEN
                linp_vor = .TRUE.
                ilev_v_max = i
             END IF
             IF (nudgd(i) >= 0.) THEN
                linp_div = .TRUE.
                ilev_d_max = i
             END IF
             IF (nudgt(i) >= 0.) THEN
                linp_tem = .TRUE.
                ilev_t_max = i
             END IF
          END DO
          
          ! clear upper part in coefficient arrays
          IF (linp_vor .AND. ilev_v_max < nlev) nudgv(ilev_v_max+1:nlev) = 0.0
          IF (linp_div .AND. ilev_d_max < nlev) nudgd(ilev_d_max+1:nlev) = 0.0
          IF (linp_tem .AND. ilev_t_max < nlev) nudgt(ilev_t_max+1:nlev) = 0.0

          ! initialize lower bound
          ilev_v_min = ilev_v_max
          ilev_d_min = ilev_d_max
          ilev_t_min = ilev_t_max

          ! find minimum level
          DO i = ilev_v_max,1,-1
             IF (nudgv(i) < 0.) EXIT
             ilev_v_min = i
          END DO
          DO i = ilev_d_max,1,-1
             IF (nudgd(i) < 0.) EXIT
             ilev_d_min = i
          END DO
          DO i = ilev_t_max,1,-1
             IF (nudgt(i) < 0.) EXIT
             ilev_t_min = i
          END DO

          ! clear lower part in coefficient arrays
          IF (ilev_v_min > 1) nudgv(1:ilev_v_min-1) = 0.0
          IF (ilev_d_min > 1) nudgd(1:ilev_d_min-1) = 0.0
          IF (ilev_t_min > 1) nudgt(1:ilev_t_min-1) = 0.0

          ino_v_lev = 0
          ino_d_lev = 0
          ino_t_lev = 0
          IF (linp_vor) ino_v_lev = ilev_v_max - ilev_v_min + 1
          IF (linp_div) ino_d_lev = ilev_d_max - ilev_d_min + 1
          IF (linp_tem) ino_t_lev = ilev_t_max - ilev_t_min + 1
          IF (nudgp >= 0.) THEN
             linp_lnp = .TRUE.
             ino_t_lev = ino_t_lev + 1
             IF (.NOT. linp_tem) ilev_t_min = 1
          ELSE
             nudgp = 0.0
          END IF

          ! correct level intervall
          IF (linp_vor .AND. linp_div .AND. linp_tem) THEN
             nudglmin = MAX(nudglmin, MIN(ilev_v_min, ilev_d_min, ilev_t_min))
             nudglmax = MIN(nudglmax, MAX(ilev_v_max, ilev_d_max, ilev_t_max))
          ELSE IF (linp_vor .AND. linp_div ) THEN
             nudglmin = MAX(nudglmin, MIN(ilev_v_min, ilev_d_min))
             nudglmax = MIN(nudglmax, MAX(ilev_v_max, ilev_d_max))
          ELSE IF (linp_vor .AND. linp_tem) THEN
             nudglmin = MAX(nudglmin, MIN(ilev_v_min, ilev_t_min))
             nudglmax = MIN(nudglmax, MAX(ilev_v_max, ilev_t_max))
          ELSE IF (linp_div .AND. linp_tem) THEN
             nudglmin = MAX(nudglmin, MIN(ilev_d_min, ilev_t_min))
             nudglmax = MIN(nudglmax, MAX(ilev_d_max, ilev_t_max))
          ELSE IF (linp_vor) THEN
             nudglmin = MAX(nudglmin, ilev_v_min)
             nudglmax = MIN(nudglmax, ilev_v_max)
          ELSE IF (linp_div) THEN
             nudglmin = MAX(nudglmin, ilev_d_min)
             nudglmax = MIN(nudglmax, ilev_d_max)
          ELSE IF (linp_tem) THEN
             nudglmin = MAX(nudglmin, ilev_t_min)
             nudglmax = MIN(nudglmax, ilev_t_max)
          END IF

          IF (lnudgdbx) THEN
             IF (linp_vor) THEN
                WRITE(ndg_mess,*) ' use external vorticity   LEVELS = (',ilev_v_min,':',ilev_v_max,')'
                CALL message('',ndg_mess)
             END IF
             IF (linp_div) THEN
                WRITE(ndg_mess,*) ' use external divergence  LEVELS = (',ilev_d_min,':',ilev_d_max,')'
                CALL message('',ndg_mess)
             END IF
             IF (linp_tem) THEN
                WRITE(ndg_mess,*) ' use external temperature LEVELS = (',ilev_t_min,':',ilev_t_max,')'
                CALL message('',ndg_mess)
             END IF
             IF (linp_lnp) THEN
                WRITE(ndg_mess,*) ' use external log surface pressue'
                CALL message('',ndg_mess)
             END IF
          END IF

          ! correct nudging coefficients
          IF (.NOT. linp_vor) nudgv(:) = 0.0
          IF (.NOT. linp_div) nudgd(:) = 0.0
          IF (.NOT. linp_tem) nudgt(:) = 0.0
          IF (.NOT. linp_lnp) nudgp    = 0.0

          IF (lnudgdbx) THEN
             WRITE(ndg_mess,*) '  modified level          LEVEL = ',nudglmin,' ... ',nudglmax
             CALL message('',ndg_mess)
          END IF

          ! ***** rescale nudging coefficients and merge with level window
          IF (nudglmin > 1) THEN
             nudgd(1:nudglmin-1) = 0.0
             nudgv(1:nudglmin-1) = 0.0
             nudgt(1:nudglmin-1) = 0.0
          ENDIF
          IF (nudglmax < nlev) THEN
             nudgd(nudglmax+1:nlev) = 0.0
             nudgv(nudglmax+1:nlev) = 0.0
             nudgt(nudglmax+1:nlev) = 0.0
          ENDIF

          !----------------------------------------------------------------
          ! prepare nudging weights level dependend
          !
          ! set weights for explicit nudging
          ! new = N(read)*2*dt*nfact
          ! rescale coefficients
          nudgdo(:) = nudgd(1:nlev) * nfact * twodt
          nudgvo(:) = nudgv(1:nlev) * nfact * twodt
          nudgto(:) = nudgt(1:nlev) * nfact * twodt
          nudgpo    = nudgp         * nfact * twodt

          ! set weights for model data
          IF (lnudgpat) THEN
             nudgd(1:nlev)  = 1.
             nudgv(1:nlev)  = 1.
             nudgt(1:nlev)  = 1.
             nudgp          = 1.
          ELSE
             nudgd(1:nlev)  = 1.-nudgdo(:)
             nudgv(1:nlev)  = 1.-nudgvo(:)
             nudgt(1:nlev)  = 1.-nudgto(:)
             nudgp          = 1.-nudgpo
          END IF

          ! convert coefficients for implicit nudging
          IF (lnudgimp) THEN
             ! using implicit nudging reset weights
             nudgd(1:nlev) = 1./(1.+nudgdo(:))
             nudgv(1:nlev) = 1./(1.+nudgvo(:))
             nudgt(1:nlev) = 1./(1.+nudgto(:))
             nudgp         = 1./(1.+nudgpo)
             
             ! reset weights for observations
             nudgdo(:) = nudgdo(:) * nudgd(1:nlev) 
             nudgvo(:) = nudgvo(:) * nudgv(1:nlev) 
             nudgto(:) = nudgto(:) * nudgt(1:nlev) 
             nudgpo    = nudgpo    * nudgp
          ENDIF

          ! now the preleminary weights are calculated
          ! NUDG[DVTP] for model value
          ! NUDG[DVTP]O for assimialtion (observation) data

          IF (lnudgdbx) THEN
             WRITE(ndg_mess,*) &
&               'Nudging coefficients (1/sec) and weights for model and observations (%)'
             CALL message('',ndg_mess)
             WRITE(ndg_mess,'(a5,3a25,7x)') 'lev','DIV','VOR','TEM'
             CALL message('',ndg_mess)

             IF (lnudgimp) THEN
                CALL message('','    IMPLICIT nudging used')
                DO i=nudglmin,nudglmax
                   WRITE(ndg_mess,'(i5,3(e12.3,2f10.3))') i,&
&                    (1.0-nudgd(i))/(nudgd(i)*twodt),nudgd(i)*100.0,nudgdo(i)*100.0,&
&                    (1.0-nudgv(i))/(nudgv(i)*twodt),nudgv(i)*100.0,nudgvo(i)*100.0,&
&                    (1.0-nudgt(i))/(nudgt(i)*twodt),nudgt(i)*100.0,nudgto(i)*100.0
                   CALL message('',ndg_mess)
                ENDDO
                WRITE(ndg_mess,'(a,e12.3,2f10.3)') ' pressure = ',&
&                  (1.0-nudgp)/(nudgp*twodt),nudgp*100.0,nudgpo*100.
                CALL message('',ndg_mess)
             ELSE
                CALL message('','    EXPLICIT nudging used')
                DO i=nudglmin,nudglmax
                   WRITE(ndg_mess,'(i5,3(e12.3,2f10.3))') i,&
&                    nudgdo(i)/twodt,nudgd(i)*100.0,nudgdo(i)*100.0,&
&                    nudgvo(i)/twodt,nudgv(i)*100.0,nudgvo(i)*100.0,&
&                    nudgto(i)/twodt,nudgt(i)*100.0,nudgto(i)*100.0
                   CALL message('',ndg_mess)
                ENDDO
                WRITE(ndg_mess,'(a,e12.3,2f10.3)') ' pressure = ',&
&                  nudgpo/twodt,nudgp*100.0,nudgpo*100.0
                CALL message('',ndg_mess)
             ENDIF
          END IF
             
          !----------------------------------------------------------------
          ! set work space nudging coefficients
          !
          ALLOCATE(nudgda(nlev  ,2,local_decomposition%snsp)); nudgda(:,:,:) = 0.0
          ALLOCATE(nudgdb(nlev  ,2,local_decomposition%snsp))
          ALLOCATE(nudgva(nlev  ,2,local_decomposition%snsp)); nudgva(:,:,:) = 0.0
          ALLOCATE(nudgvb(nlev  ,2,local_decomposition%snsp))
          ALLOCATE(nudgta(nlevp1,2,local_decomposition%snsp)); nudgta(:,:,:) = 0.0
          ALLOCATE(nudgtb(nlevp1,2,local_decomposition%snsp))

          CALL message('','')

          !----------------------------------------------------------------
          ! initialize nudging fields

          IF (linp_div) THEN
             ALLOCATE (sdobs0(nlev  ,2,local_decomposition%snsp)); sdobs0(:,:,:) = 0.
             ALLOCATE (sdobs1(nlev  ,2,local_decomposition%snsp)); sdobs1(:,:,:) = 0.
             ALLOCATE (sdobs2(nlev  ,2,local_decomposition%snsp)); sdobs2(:,:,:) = 0.
             ALLOCATE (sdobs3(nlev  ,2,local_decomposition%snsp)); sdobs3(:,:,:) = 0.

             IF (ioflag) THEN
                ALLOCATE (sdobs3_global(nlev  ,2,nsp)); sdobs3(:,:,:) = 0.
             END IF
          END IF
 
          IF (linp_vor) THEN
             ALLOCATE (svobs0(nlev  ,2,local_decomposition%snsp)); svobs0(:,:,:) = 0.
             ALLOCATE (svobs1(nlev  ,2,local_decomposition%snsp)); svobs1(:,:,:) = 0.
             ALLOCATE (svobs2(nlev  ,2,local_decomposition%snsp)); svobs2(:,:,:) = 0.
             ALLOCATE (svobs3(nlev  ,2,local_decomposition%snsp)); svobs3(:,:,:) = 0.

             IF (ioflag) THEN
                ALLOCATE (svobs3_global(nlev  ,2,nsp)); sdobs3(:,:,:) = 0.
             END IF
          END IF

          IF (linp_tem .OR. linp_lnp) THEN
             ALLOCATE (stobs0(nlevp1,2,local_decomposition%snsp)); stobs0(:,:,:) = 0.
             ALLOCATE (stobs1(nlevp1,2,local_decomposition%snsp)); stobs1(:,:,:) = 0.
             ALLOCATE (stobs2(nlevp1,2,local_decomposition%snsp)); stobs2(:,:,:) = 0.
             ALLOCATE (stobs3(nlevp1,2,local_decomposition%snsp)); stobs3(:,:,:) = 0.

             IF (ioflag) THEN
                ALLOCATE (stobs3_global(nlevp1,2,nsp)); sdobs3(:,:,:) = 0.
             END IF

          END IF

          ALLOCATE (sdobs(nlev  ,2,local_decomposition%snsp));  sdobs(:,:,:) = 0.
          ALLOCATE (svobs(nlev  ,2,local_decomposition%snsp));  svobs(:,:,:) = 0.
          ALLOCATE (stobs(nlevp1,2,local_decomposition%snsp));  stobs(:,:,:) = 0.

          ! allocate SITE memory
          IF (lsite) THEN
             lsite_n0 = .FALSE.
             lsite_n1 = .FALSE.
!             IF (linp_div) THEN
                ALLOCATE (sd_o_n0(nlev  ,2,nsp)); sd_o_n0(:,:,:) = 0.0
                ALLOCATE (sd_o_n1(nlev  ,2,nsp)); sd_o_n1(:,:,:) = 0.0
                ALLOCATE (sd_m_n0(nlev  ,2,nsp)); sd_m_n0(:,:,:) = 0.0
                ALLOCATE (sd_m_n1(nlev  ,2,nsp)); sd_m_n1(:,:,:) = 0.0
                ALLOCATE (sdsite(nlev  ,2,nsp)); sdsite(:,:,:) = 0.0
!             END IF
!             IF (linp_vor) THEN
                ALLOCATE (sv_o_n0(nlev  ,2,nsp)); sv_o_n0(:,:,:) = 0.0
                ALLOCATE (sv_o_n1(nlev  ,2,nsp)); sv_o_n1(:,:,:) = 0.0
                ALLOCATE (sv_m_n0(nlev  ,2,nsp)); sv_m_n0(:,:,:) = 0.0
                ALLOCATE (sv_m_n1(nlev  ,2,nsp)); sv_m_n1(:,:,:) = 0.0
                ALLOCATE (svsite(nlev  ,2,nsp)); svsite(:,:,:) = 0.0
!             END IF
!             IF (linp_tem .OR. linp_lnp) THEN
                ALLOCATE (st_o_n0(nlevp1,2,nsp)); st_o_n0(:,:,:) = 0.0
                ALLOCATE (st_o_n1(nlevp1,2,nsp)); st_o_n1(:,:,:) = 0.0
                ALLOCATE (st_m_n0(nlevp1,2,nsp)); st_m_n0(:,:,:) = 0.0
                ALLOCATE (st_m_n1(nlevp1,2,nsp)); st_m_n1(:,:,:) = 0.0
                ALLOCATE (stsite(nlevp1,2,nsp)); stsite(:,:,:) = 0.0
!             END IF
             isiteaccu = 0
          END IF

          ! allocate memory for fast modes
          ! needed for tendency diagnostics using SNMI
          lfill_a = .FALSE.
          lfill_b = .FALSE.
          ifast_accu = 0
          IF (lnmi) THEN
             ALLOCATE (sdfast_a(nlev  ,2,nsp)); sdfast_a(:,:,:) = 0.0
             ALLOCATE (svfast_a(nlev  ,2,nsp)); svfast_a(:,:,:) = 0.0
             ALLOCATE (stfast_a(nlevp1,2,nsp)); stfast_a(:,:,:) = 0.0

             ALLOCATE (sdfast_b(nlev  ,2,nsp)); sdfast_b(:,:,:) = 0.0
             ALLOCATE (svfast_b(nlev  ,2,nsp)); svfast_b(:,:,:) = 0.0
             ALLOCATE (stfast_b(nlevp1,2,nsp)); stfast_b(:,:,:) = 0.0

             ALLOCATE (sdfast_accu(nlev  ,2,nsp)); sdfast_accu(:,:,:) = 0.0
             ALLOCATE (svfast_accu(nlev  ,2,nsp)); svfast_accu(:,:,:) = 0.0
             ALLOCATE (stfast_accu(nlevp1,2,nsp)); stfast_accu(:,:,:) = 0.0
          END IF

          ALLOCATE (sdten(nlev  ,2,local_decomposition%snsp))
          ALLOCATE (svten(nlev  ,2,local_decomposition%snsp))
          ALLOCATE (stten(nlevp1,2,local_decomposition%snsp))
       
          ALLOCATE (sdtac(nlev  ,2,local_decomposition%snsp)); sdtac(:,:,:) = 0.0
          ALLOCATE (svtac(nlev  ,2,local_decomposition%snsp)); svtac(:,:,:) = 0.0
          ALLOCATE (sttac(nlevp1,2,local_decomposition%snsp)); sttac(:,:,:) = 0.0

          ! allocate the memory for additional diagnostics
          lrescor_a = .FALSE.
          lrescor_b = .FALSE.

          ALLOCATE (sdres_a(nlev  ,2,local_decomposition%snsp)); sdres_a(:,:,:) = 0.0
          ALLOCATE (svres_a(nlev  ,2,local_decomposition%snsp)); svres_a(:,:,:) = 0.0
          ALLOCATE (stres_a(nlevp1,2,local_decomposition%snsp)); stres_a(:,:,:) = 0.0

          ALLOCATE (sdres_b(nlev  ,2,local_decomposition%snsp)); sdres_b(:,:,:) = 0.0
          ALLOCATE (svres_b(nlev  ,2,local_decomposition%snsp)); svres_b(:,:,:) = 0.0
          ALLOCATE (stres_b(nlevp1,2,local_decomposition%snsp)); stres_b(:,:,:) = 0.0

          ! additional field for pattern assimilation
          IF (lnudgpat) THEN
             ! global fields from external data files
             ALLOCATE(a_pat_vor(nlev,  4)); a_pat_vor(:,:) = 0.0
             ALLOCATE(a_pat_div(nlev,  4)); a_pat_div(:,:) = 0.0
             ALLOCATE(a_pat_tem(nlevp1,4)); a_pat_tem(:,:) = 0.0
             ALLOCATE(a_pat_lnp       (4)); a_pat_lnp  (:) = 0.0
             ! norm of pattern
             ALLOCATE(a_nrm_vor(nlev,  4)); a_nrm_vor(:,:) = 0.0
             ALLOCATE(a_nrm_div(nlev,  4)); a_nrm_div(:,:) = 0.0
             ALLOCATE(a_nrm_tem(nlevp1,4)); a_nrm_tem(:,:) = 0.0
             ALLOCATE(a_nrm_lnp       (4)); a_nrm_lnp  (:) = 0.0
             ! local field, corrected each time step
             ALLOCATE(b_pat_vor(nlev,2)); b_pat_vor(:,:) = 0.0
             ALLOCATE(b_pat_div(nlev,2)); b_pat_div(:,:) = 0.0
             ALLOCATE(b_pat_tem(nlev,2)); b_pat_tem(:,:) = 0.0
             ALLOCATE(b_pat_lnp     (2)); b_pat_lnp  (:) = 0.0
          END IF

          if (ioflag) THEN
             ALLOCATE(worksp_global(1,2,nsp)) ! output buffer

             CALL message('NudgingInit','****** memory allocated *****')
          END if

          ! reload old restart data
          IF (.NOT.lnudgini) CALL NudgingRerun(NDG_RERUN_RD)

          IF (lsite) THEN
             ! in old model site was with other meaning in rerun files
             ! preliminary correction
             sdsite(:,:,:) = 0.0
             svsite(:,:,:) = 0.0
             stsite(:,:,:) = 0.0
          END IF

       CASE default
          CALL finish('NudgingInit','wrong initialization mode')

       END SELECT

    ELSE

!-- B. no nudging

       !----------------------------------------------------------------
       ! read nudging namelist
       IF (ioflag) THEN
          CALL message('NudgingInit',' skip namelist')
          READ (nin,ndgctl)
       ENDIF

    ENDIF

    RETURN

  END SUBROUTINE NudgingInit
!======================================================================

  SUBROUTINE Nudging

    ! -------------------------------------------------------------------
    !    New 'nudging' routine for ECHAM4 to adjust the following 
    !    meteorological variables to observations by means of
    !    Newtonian relaxation:  - divergence
    !                           - vorticity
    !                           - temperature
    !                           - log surface pressure
    !

    REAL    :: wobs, wmod, rtwodt, tfact0, tfact1, tfact2, tfact3
    INTEGER :: jk
    REAL    :: tu0, ts0, tu1, ts1
    REAL    :: dt0, dt1, dt2, dt3, dt4, dtx1, dtx2, dtx3
    LOGICAL :: lbetaprn

    INTEGER :: my_day, ymd

    INTEGER :: date, yr, day, step_a, step_b

    INTEGER, EXTERNAL :: util_cputime

    lbetaprn = .FALSE.

    IF (lnudgdbx) THEN
       IF (util_cputime(tu0,ts0) == -1) THEN
          CALL message('Nudging','Cannot determine used CPU time')
       END IF
    END IF

    ! *** initalize instantaneous tendencies
    sdten(:,:,:) = 0.0
    svten(:,:,:) = 0.0
    stten(:,:,:) = 0.0
   
    rtwodt = 1./twodt

    ! *** read nudging data arrays, minimum of four time steps
    CALL GetNudgeData

    ! --------------------------------------------------------------------
    ! *** time interpolation and damping of nudging strength

    dt0 = REAL(ndgstep1 - ndgstep0)
    dt1 = REAL(ndgstep2 - ndgstep1)
    dt2 = REAL(ndgstep3 - ndgstep2)

    dt3 = REAL(ndgstep2 - ndgstep0)/dt1
    dt4 = REAL(ndgstep3 - ndgstep1)/dt1

    IF (lnudgcli) THEN

       ! adjustment to the beginning of the year

       date = ic2ymd(ncbase+INT(((nstep+1)*dtime + ntbase + 0.0001)/dayl))
       yr   = date/10000
       IF (yr < 1) THEN          ! (YY-1)0101 = 1.1.previousyear
         ymd  = (yr-1) * 10000 - 101
       ELSE
         ymd  = (yr-1) * 10000 + 101
       END IF

       day  = iymd2c(ymd)  ! (YY-1)0101 = 1.1.previousyear
       IF (day - ncbase > 0) THEN
          step_a = INT(((day-ncbase)*dayl - ntbase +0.0001 )/dtime)
       ELSE
          step_a = INT(((day-ncbase)*dayl - ntbase -0.0001 )/dtime)
       END IF

       ! construction of a two year cycle for adjustment
       ! in climate mode data of one year must be in one file
       day  = iymd2c(10000 + 101)
       step_b = INT((day*dayl +0.0001)/dtime)


       dtx1 = REAL((nstep+1-step_a) - (ndgstep1-step_b))/dt1
       WRITE(*,*) 'INTERPOLATION (nstep+1 -  A) ',nstep+1,' - ',step_a,&
            ' ndgstep1 ',ndgstep1,((nstep+1-step_a) - (ndgstep1-step_b)),&
            ' ndgstep2 ',ndgstep2,dtx1

    ELSE

       dtx1 = REAL(nstep+1 - ndgstep1)/dt1

    END IF

    sdobs(:,:,:) = 0.0
    svobs(:,:,:) = 0.0
    stobs(:,:,:) = 0.0

    IF (lnudgpat) THEN
       ! special case pattern correlation
       tfact2 = dtx1
       tfact1 = 1.-tfact2

       ! calculates b_pat_xxx = a_pat_xxx + NORM(model,obs)
       CALL Nudg_Update_Alpha

       ! set lbetaprn
       my_day = MOD(sheadd,100)
       IF (sheadt == 120000) lbetaprn = .TRUE.

       IF (linp_div) THEN
          DO jk=1,nlev
             sdobs(jk,:,:) = sdobs1(jk,:,:)*tfact1*b_pat_div(jk,1) &
                           + sdobs2(jk,:,:)*tfact2*b_pat_div(jk,2)
          END DO
          IF (lbetaprn) THEN
             WRITE(ndg_mess,'(a,40f12.4)') 'BETA(div)1= ',b_pat_div(:,1)
             CALL message('Nudging',ndg_mess)
             WRITE(ndg_mess,'(a,40f12.4)') 'BETA(div)2= ',b_pat_div(:,2)
             CALL message('Nudging',ndg_mess)
          END IF
          
       END IF

       IF (linp_vor) THEN
          DO jk=1,nlev
             svobs(jk,:,:) = svobs1(jk,:,:)*tfact1*b_pat_vor(jk,1) &
                           + svobs2(jk,:,:)*tfact2*b_pat_vor(jk,2)
          END DO
          IF (lbetaprn) THEN
             WRITE(ndg_mess,'(a,40f12.4)') 'BETA(vor)1= ',b_pat_vor(:,1)
             CALL message('Nudging',ndg_mess)
             WRITE(ndg_mess,'(a,40f12.4)') 'BETA(vor)2= ',b_pat_vor(:,2)
             CALL message('Nudging',ndg_mess)
          END IF
       END IF

       IF (linp_tem) THEN
          DO jk=1,nlev
             stobs(jk,:,:) = stobs1(jk,:,:)*tfact1*b_pat_tem(jk,1) &
                           + stobs2(jk,:,:)*tfact2*b_pat_tem(jk,2)
          END DO
          IF (lbetaprn) THEN
             WRITE(ndg_mess,'(a,40f12.4)') 'BETA(tem)1= ',b_pat_tem(:,1)
             CALL message('Nudging',ndg_mess)
             WRITE(ndg_mess,'(a,40f12.4)') 'BETA(tem)2= ',b_pat_tem(:,2)
             CALL message('Nudging',ndg_mess)
          END IF
       END IF

       IF (linp_lnp) THEN
          stobs(nlevp1,:,:) = stobs1(nlevp1,:,:)*tfact1*b_pat_lnp(1) &
                            + stobs2(nlevp1,:,:)*tfact2*b_pat_lnp(2)
          IF (lbetaprn) THEN
             WRITE(ndg_mess,'(a,40f12.4)') 'BETA(lnp)1= ',b_pat_lnp(1)
             CALL message('Nudging',ndg_mess)
             WRITE(ndg_mess,'(a,40f12.4)') 'BETA(lnp)2= ',b_pat_lnp(2)
             CALL message('Nudging',ndg_mess)
          END IF
       END IF

       IF (lnudgdbx) THEN
          WRITE(ndg_mess,'(a,2(f8.4,1x),a,i10)') &
&               '2 time factors ',tfact1,tfact2,' at NSTEP+1 = ',nstep+1
          CALL message('Nudging',ndg_mess)
       END IF

    ELSEIF (ltintlin) THEN
       ! linear time interpolation
       tfact2 = dtx1
       tfact1 = 1.-tfact2
       IF (linp_div) &
            sdobs(:,:,:) = sdobs1(:,:,:)*tfact1 + sdobs2(:,:,:)*tfact2
       IF (linp_vor) &
            svobs(:,:,:) = svobs1(:,:,:)*tfact1 + svobs2(:,:,:)*tfact2
       IF (linp_tem) &
            stobs(1:nlev,:,:) = stobs1(1:nlev,:,:)*tfact1 + stobs2(1:nlev,:,:)*tfact2
       IF (linp_lnp) &
            stobs(nlevp1,:,:) = stobs1(nlevp1,:,:)*tfact1 + stobs2(nlevp1,:,:)*tfact2

       IF (lnudgdbx) THEN
          WRITE(ndg_mess,'(a,2(f8.4,1x),a,i10)') &
&               '2 time factors ',tfact1,tfact2,' at NSTEP+1 = ',nstep+1
          CALL message('Nudging',ndg_mess)
       END IF
    ELSE
       ! non-linear interpolation, use polynom 3rd order solution
       dtx2 = dtx1*dtx1
       dtx3 = dtx2*dtx1
       tfact0 = (-dtx2 +2.*dtx1 -1.)*dtx1/dt3
       tfact1 = ((2.*dt4-1.)*dtx3 +(1.-3.*dt4)*dtx2 +dt4)/dt4
       tfact2 = ((1.-2.*dt3)*dtx2 +(3.*dt3-2.)*dtx1 +1.)*dtx1/dt3
       tfact3 = (dtx1-1.)*dtx2/dt4

       IF (linp_div) &
            sdobs(:,:,:) = &
&            sdobs0(:,:,:)*tfact0 +sdobs1(:,:,:)*tfact1 +&
&            sdobs2(:,:,:)*tfact2 +sdobs3(:,:,:)*tfact3
       IF (linp_vor) &
            svobs(:,:,:) = &
&            svobs0(:,:,:)*tfact0 +svobs1(:,:,:)*tfact1 +&
&            svobs2(:,:,:)*tfact2 +svobs3(:,:,:)*tfact3
       IF (linp_tem) &
            stobs(1:nlev,:,:) = &
&            stobs0(1:nlev,:,:)*tfact0 +stobs1(1:nlev,:,:)*tfact1 +&
&            stobs2(1:nlev,:,:)*tfact2 +stobs3(1:nlev,:,:)*tfact3
       IF (linp_lnp) &
            stobs(nlevp1,:,:) = &
&            stobs0(nlevp1,:,:)*tfact0 +stobs1(nlevp1,:,:)*tfact1 +&
&            stobs2(nlevp1,:,:)*tfact2 +stobs3(nlevp1,:,:)*tfact3

       IF (lnudgdbx) THEN
          WRITE(ndg_mess,'(a,4(f8.4,1x),a,i10)') &
&               '4 time factors ',tfact0,tfact1,tfact2,tfact3,' at NSTEP+1 = ',nstep+1
          CALL message('Nudging',ndg_mess)
       END IF
    END IF

    IF ((nudgdsize < dtx1) .AND. (dtx1 < (1.-nudgdsize)) ) THEN
       wobs = nudgdamp
    ELSE
       IF (dtx1 > 0.5 ) dtx1 = 1.-dtx1    ! right window side mirrored
       IF (nudgdsize <= 0.0) THEN
          wobs = 0.0
       ELSE IF (ldamplin) THEN
          ! linear time damping weight
          wobs = 1. - dtx1 * (1.-nudgdamp)/nudgdsize
       ELSE
          ! non -linear damping
          dtx1 = dtx1/nudgdsize             ! rescale x-axis
          wobs = dtx1*dtx1*(nudgdamp-1.)*(3.-2.*dtx1)+1.
       END IF
    END IF
    wobs = MAX(MIN(wobs,1.),0.)
    wmod = 1.-wobs
    IF (lnudgdbx) THEN
       WRITE(ndg_mess,'(a,f7.4,a,f7.4)') 'weights OBS=  ',wobs,' MOD= ',wmod
       CALL message('Nudging',ndg_mess)
    END IF

    ! --------------------------------------------------------------------
    ! *** Normal Mode Filter
    IF (lnmi .AND. (.NOT.lnudgfrd)) CALL NMI_Make(NMI_MAKE_FMMO)

    ! --------------------------------------------------------------------
    ! *** setup coefficient matrix
    ! inside nudging region
    !   A = (nudg? + wmod*nudg?o)
    !   B = wobs*nudg?o
    ! outside nudging region
    !   A = 1.0
    !   B = 0.0

    DO jk=1,nlev
       nudgda(jk,:,:) = flago(jk,:,:) + flagn(jk,:,:)*(nudgd(jk) + wmod*nudgdo(jk))
       nudgdb(jk,:,:) =                 flagn(jk,:,:)*             wobs*nudgdo(jk)

       nudgva(jk,:,:) = flago(jk,:,:) + flagn(jk,:,:)*(nudgv(jk) + wmod*nudgvo(jk))
       nudgvb(jk,:,:) =                 flagn(jk,:,:)*             wobs*nudgvo(jk)

       nudgta(jk,:,:) = flago(jk,:,:) + flagn(jk,:,:)*(nudgt(jk) + wmod*nudgto(jk))
       nudgtb(jk,:,:) =                 flagn(jk,:,:)*             wobs*nudgto(jk)
    END DO
    jk = nlevp1
    nudgta(jk,:,:) = flago(jk,:,:) + flagn(jk,:,:)*(nudgp + wmod*nudgpo)
    nudgtb(jk,:,:) =                 flagn(jk,:,:)*         wobs*nudgpo


    ! --------------------------------------------------------------------
    !   Set the complex part of the global means to 0.
    ! --------------------------------------------------------------------
    IF (local_decomposition%sm(1) == 0 .AND. local_decomposition%snn0(1) == 0) THEN
       sdobs(:,2,1) = 0.
       svobs(:,2,1) = 0.
       stobs(:,2,1) = 0.
    END IF

    !--------------------------------------------------------------------
    !  Now perform Newtonian relaxation.
    !
    !  Apply full nudging for all scales. For T106 run, it may be
    !  necessary to decrease weight for smaller scales.
    !  Originally, there was full nudging up to T42 (NSP<=946), 50%
    !  at T63 (NSP=2080) and no nudging for NSP>2628 (T71).
    !--------------------------------------------------------------------
    !
    ! --------------------------------------------------------------------
    !   Tendencies are defined as the difference between the 
    !   nudged and the original fields
    !
    !        T_tendency := T_nudging  - T_original,    ergo 
    !   >>>  T_nudging   = T_original + T_tendency  <<<
    ! --------------------------------------------------------------------
    

    ! store old model values
    sdten(:,:,:) = sd (:,:,:)
    svten(:,:,:) = svo(:,:,:)
    stten(:,:,:) = stp(:,:,:)


    IF (lnudg_do) THEN

       ! calculate new model value as linear combination of old model value and observations
       ! calculate in nudging window (nudglmin:nudglmax,nudgmin:nudgmax)
       !
       ! NEW = A * OLD + B * OBS

       sd (:,:,:)   = nudgda(:,:,:)*sd (:,:,:) + nudgdb(:,:,:)*sdobs(:,:,:)
       svo(:,:,:)   = nudgva(:,:,:)*svo(:,:,:) + nudgvb(:,:,:)*svobs(:,:,:)
       stp(:,:,:)   = nudgta(:,:,:)*stp(:,:,:) + nudgtb(:,:,:)*stobs(:,:,:)

    END IF


    ! compose diagnostics with flag-fields
    !
    ! INSIDE
    ! store nudging term , tendency term, (NEW-OLD)/2DT in UNIT/sec
    !
    ! OUTSIDE
    ! calculate difference outside the nudging range, absolut value
    ! MODEL - OBSERVED in UNIT
    !
    sdten(:,:,:) = &
&         flagn(1:nlev,:,:)*(sd (:,:,:) - sdten(:,:,:))*rtwodt + &
&         flago(1:nlev,:,:)*(sd (:,:,:) - sdobs(:,:,:))

    svten(:,:,:) = &
&         flagn(1:nlev,:,:)*(svo(:,:,:) - svten(:,:,:))*rtwodt + &
&         flago(1:nlev,:,:)*(svo(:,:,:) - svobs(:,:,:))

    stten(:,:,:) = &
&         flagn(:,:,:)*(stp(:,:,:) - stten(:,:,:))*rtwodt + &
&         flago(:,:,:)*(stp(:,:,:) - stobs(:,:,:))

    ! accumulation of diagnostics

    sdtac(:,:,:) = sdtac(:,:,:) + sdten(:,:,:)
    svtac(:,:,:) = svtac(:,:,:) + svten(:,:,:)
    sttac(:,:,:) = sttac(:,:,:) + stten(:,:,:)

    IF (lsite) THEN
       IF (lsite_n0) THEN
          ! accumulate SITEs
          !   fraction is  (X[n+1]-X[n-1])/2dt - Residue - (O[n+1]-O[n-1])/2dt
          !
          sdsite(:,:,:) = sdsite(:,:,:) &
               + (sd (:,:,:) - sd_m_n0)*rtwodt - flagn(:,:,:)*sdten(:,:,:) &
               - (sdobs(:,:,:) - sd_o_n0)*rtwodt

          svsite(:,:,:) = svsite(:,:,:) &
               + (svo(:,:,:) - sv_m_n0)*rtwodt - flagn(:,:,:)*svten(:,:,:) &
               - (svobs(:,:,:) - sv_o_n0)*rtwodt

          stsite(:,:,:) = stsite(:,:,:) &
               + (stp(:,:,:) - st_m_n0)*rtwodt - flagn(:,:,:)*stten(:,:,:) &
               - (stobs(:,:,:) - st_o_n0)*rtwodt

          isiteaccu = isiteaccu + 1
       END IF

       ! store in SITE detection mode observed/modelled values from the last step
       IF (lsite_n1) THEN
          lsite_n0 = .TRUE.
          sd_o_n0(:,:,:) = sd_o_n1(:,:,:)
          sv_o_n0(:,:,:) = sv_o_n1(:,:,:)
          st_o_n0(:,:,:) = st_o_n1(:,:,:)

          sd_m_n0(:,:,:) = sd_m_n1(:,:,:)
          sv_m_n0(:,:,:) = sv_m_n1(:,:,:)
          st_m_n0(:,:,:) = st_m_n1(:,:,:)
       END IF
       lsite_n1 = .TRUE.
       sd_o_n1(:,:,:) = sdobs(:,:,:)
       sv_o_n1(:,:,:) = svobs(:,:,:)
       st_o_n1(:,:,:) = stobs(:,:,:)

       ! store corrected value
       sd_m_n1(:,:,:) = sd (:,:,:)
       sv_m_n1(:,:,:) = svo(:,:,:)
       st_m_n1(:,:,:) = stp(:,:,:)

    END IF

    iaccu = iaccu + 1

    ! store the tendency for later usage
    IF (.NOT.lptime) CALL Nudge_ResidueStore

    IF (lnudgdbx) THEN
       IF (util_cputime(tu1, ts1) == -1) THEN
          CALL message('Nudging',' Cannot determine used CPU time')
       ELSE
          WRITE (ndg_mess,'(a,i10,f10.3,a)')&
&               'performance at NSTEP ',nstep,&
&               (tu1+ts1)-(tu0+ts0),'s (user+system) '

          CALL message('Nudging',ndg_mess)
       END IF
    END IF

  END SUBROUTINE Nudging
!======================================================================
!
! I/O NUDGING DATA
!
!======================================================================

  SUBROUTINE GetNudgeData

    ! read new data for nudging, dependend on the time step

    INTEGER :: iday, isec, itime, date, yr, mo

    ! Intrinsic functions
    INTRINSIC MOD

    ! leap year correction
    IF (lnudgcli .AND. ly365) THEN
       date = ic2ymd(ncbase+INT(((nstep+1)*dtime + ntbase)/dayl))
       yr   = date/10000
       mo   = MOD(date/100,100)
       IF (im2day(2,yr-1) == 29) THEN
          ileap = 1
       ELSE IF ( (mo > 2) .AND. (im2day(2,yr) == 29) ) THEN
          ileap = 2
       ELSE
          ileap = 0
       END IF
    END IF
 
    ! set expected header
    itime  = ntbase + dtime*(nstep+1)
    iday   = ncbase + (itime+0.001)/dayl
    sheadd = ic2ymd(iday)    ! get year, months and day
    isec   = MOD(itime,INT(dayl))
    sheadt = isec2hms(isec) ! get hour, minute and second

    IF (lnudgcli) THEN
       ! remove year and set model year to 2
       sheadd = MOD(sheadd,10000) + 20000
    END IF

    IF (lnudgdbx) THEN
       WRITE(ndg_mess,'(a,i8.8,a,i6.6)')  'expect date ',sheadd,' time ',sheadt
       CALL message('GetNudgeData',ndg_mess)
    END IF

    ! check nudging period
    IF (lnudg_do) THEN
       IF ( (nudg_start > 0) .AND. (nudg_start > sheadd) ) lnudg_do = .FALSE.
       IF ( (nudg_stop  > 0) .AND. (nudg_stop  < sheadd) ) lnudg_do = .FALSE.
       IF ( (.NOT. lnudg_do) .AND. ioflag ) THEN
          WRITE(ndg_mess,'(a,i8.8,a,i6.6)')  ' nudging stopped at date ',sheadd,' time ',sheadt
          CALL message('GetNudgeData',ndg_mess)
       END IF
    ELSE
       IF ( (nudg_start > 0) .AND. (nudg_start == sheadd) ) lnudg_do = .TRUE.
       IF ( lnudg_do .AND. ioflag ) THEN
          WRITE(ndg_mess,'(a,i8.8,a,i6.6)')  ' nudging started at date ',sheadd,' time ',sheadt
          CALL message('GetNudgeData',ndg_mess)
       END IF
    END IF

    ! check the date and time
    IF (lndgstep3 .AND. &    ! all nudging data available
&         (compare_dati(ihead1d,ihead1t,sheadd,sheadt)<1) .AND. &
&         (compare_dati(sheadd,sheadt,ihead2d,ihead2t)<0) ) &
&         RETURN             ! no new nudging data set is neccessary

    ! nothing read before, initialize data stream
    IF (.NOT.lndgstep3) THEN
       IF (ioflag) THEN
          CALL OpenOneBlock
          CALL ReadOneBlock
       END IF
       CALL scatter_sp(sdobs3_global,sdobs3,global_decomposition)
       CALL scatter_sp(svobs3_global,svobs3,global_decomposition)
       CALL scatter_sp(stobs3_global,stobs3,global_decomposition)
       IF (p_parallel) THEN
          CALL p_bcast(ihead3d , p_io)
          CALL p_bcast(ihead3t , p_io)
          CALL p_bcast(ndgstep3 , p_io)
       END IF
       lndgstep3 = .TRUE.
    END IF

    ! search next possible nudging data which cover the model time
    read_data_loop : DO
       IF (lndgstep1) THEN
          ! now step 1 available
          lndgstep0 = .TRUE.
          ihead0d   = ihead1d
          ihead0t   = ihead1t
          ndgstep0  = ndgstep1
          IF(linp_div)               sdobs0(:,:,:) = sdobs1(:,:,:)
          IF(linp_vor)               svobs0(:,:,:) = svobs1(:,:,:)
          IF(linp_tem .OR. linp_lnp) stobs0(:,:,:) = stobs1(:,:,:)
       END IF
       IF (lndgstep2) THEN
          ! now step 2 available
          lndgstep1 = .TRUE.
          ihead1d   = ihead2d
          ihead1t   = ihead2t
          ndgstep1  = ndgstep2
          IF(linp_div)               sdobs1(:,:,:) = sdobs2(:,:,:)
          IF(linp_vor)               svobs1(:,:,:) = svobs2(:,:,:)
          IF(linp_tem .OR. linp_lnp) stobs1(:,:,:) = stobs2(:,:,:)
          IF (lnudgpat) THEN
             IF(linp_vor) THEN
                a_pat_vor(:,2) = a_pat_vor(:,3)
                a_nrm_vor(:,2) = a_nrm_vor(:,3)
             END IF
             IF(linp_div) THEN
                a_pat_div(:,2) = a_pat_div(:,3)
                a_nrm_div(:,2) = a_nrm_div(:,3)
             END IF
             IF(linp_tem) THEN
                a_pat_tem(:,2) = a_pat_tem(:,3)
                a_nrm_tem(:,2) = a_nrm_tem(:,3)
             END IF
             IF(linp_lnp) THEN
                a_pat_lnp  (2) = a_pat_lnp  (3)
                a_nrm_lnp  (2) = a_nrm_lnp  (3)
             END IF
          END IF
       END IF
       ! now step 3 available
       lndgstep2 = .TRUE.
       ihead2d   = ihead3d
       ihead2t   = ihead3t
       ndgstep2  = ndgstep3
       IF(linp_div)               sdobs2(:,:,:) = sdobs3(:,:,:)
       IF(linp_vor)               svobs2(:,:,:) = svobs3(:,:,:)
       IF(linp_tem .OR. linp_lnp) stobs2(:,:,:) = stobs3(:,:,:)
       IF (lnudgpat) THEN
          IF(linp_vor) THEN
             a_pat_vor(:,3) = a_pat_vor(:,4)
             a_nrm_vor(:,3) = a_nrm_vor(:,4)
          END IF
          IF(linp_div) THEN
             a_pat_div(:,3) = a_pat_div(:,4)
             a_nrm_div(:,3) = a_nrm_div(:,4)
          END IF
          IF(linp_tem) THEN
             a_pat_tem(:,3) = a_pat_tem(:,4)
             a_nrm_tem(:,3) = a_nrm_tem(:,4)
          END IF
          IF(linp_lnp) THEN
             a_pat_lnp  (3) = a_pat_lnp  (4)
             a_nrm_lnp  (3) = a_nrm_lnp  (4)
          END IF
       END IF

       ! read next step 4
       IF (ioflag) CALL ReadOneBlock
       CALL scatter_sp(sdobs3_global,sdobs3,global_decomposition)
       CALL scatter_sp(svobs3_global,svobs3,global_decomposition)
       CALL scatter_sp(stobs3_global,stobs3,global_decomposition)
       IF (p_parallel) THEN
          CALL p_bcast(ihead3d , p_io)
          CALL p_bcast(ihead3t , p_io)
          CALL p_bcast(ndgstep3 , p_io)
       END IF

       ! minimum of four steps is necessary only for cubic spline
       IF ( (ltintlin .AND. lndgstep1) .OR. ( (.NOT.ltintlin).AND.lndgstep0) ) THEN
!!       IF (lndgstep0) THEN
          IF ( &
&               (compare_dati(ihead1d,ihead1t,sheadd,sheadt)<1).AND. &
&               (compare_dati(sheadd,sheadt,ihead2d,ihead2t)<0) ) THEN
             ! window fit the calculation time step
             EXIT
          ELSE IF (.NOT. lnudgcli .AND. compare_dati(ihead1d,ihead1t,sheadd,sheadt)>0) THEN
             ! missing data at the beginning
             WRITE(ndg_mess,*) 'nudging not before ',ihead1d,ihead1t,' but needed ',sheadd,sheadt
             CALL finish('GetNudgeData',ndg_mess)
          END IF
       END IF

    END DO read_data_loop

    IF (lnudgdbx) THEN
       WRITE(ndg_mess,'(a,i8,1x,i6.6,1x,i10,a,i8,1x,i6.6,1x,i10)') &
&            'interpolate between (date/time/step) ',ihead1d,ihead1t,ndgstep1 &
&            ,' and ',ihead2d,ihead2t,ndgstep2
       CALL message('GetNudgeData',ndg_mess)
    END IF

  CONTAINS
    FUNCTION compare_dati(date1,time1,date2,time2)
      INTEGER :: compare_dati
      INTEGER :: date1, date2 ! YYYYMMDD
      INTEGER :: time1, time2 ! HHMMSS
      ! -1 ... (date1,time1) < (date2,time2)
      !  0 ... (date1,time1) = (date2,time2)
      !  1 ... (date1,time1) > (date2,time2)
      compare_dati = 1
      IF ((date1==date2).AND.(time1==time2)) THEN
         compare_dati = 0
      ELSE IF( (date1 < date2) .OR. &
&           ((date1==date2).AND.(time1<time2)) ) THEN
         compare_dati = -1
      END IF
    END FUNCTION compare_dati

  END SUBROUTINE GetNudgeData
!======================================================================

  SUBROUTINE ReadOneBlock
    ! read next nudging data time step

    INTEGER           :: kret, iilen, iday
    INTEGER           :: ilen_d, ilen_v, ilen_t
    INTEGER           :: iheadd(8), iheadv(8), iheadt(8)
    CHARACTER (8)     :: yhead(8)
    REAL, ALLOCATABLE :: phbuf(:), zhbuf(:)
    LOGICAL  :: lrd_check

    ! Intrinsic functions
    INTRINSIC MAX, RESHAPE

    ilen_d = n2sp*ino_d_lev
    ilen_v = n2sp*ino_v_lev
    ilen_t = n2sp*ino_t_lev

    iilen = MAX(ilen_d,ilen_v,ilen_t)
    ALLOCATE(phbuf(iilen))
#ifndef CRAY
    ALLOCATE(zhbuf(iilen))
    zhbuf(:) = 0.0
#endif

    read_records : DO
       ! read next nudging data set header
       IF (linp_div) THEN
          SELECT CASE(ndgfmt)
          CASE('cray')
             CALL cpbread(kfiled,yhead,8*8,kret)
             IF (kret==8*8) CALL util_i8toi4 (yhead(1), iheadd(1),8)
          CASE('ieee')
             READ(unit=ndunit(15),iostat=kret) iheadd
             if (kret == 0) kret = 8*8

          END SELECT
          IF(kret==8*8 .AND. iheadd(1)/=155) THEN
             WRITE(ndg_mess,*) 'HEADER DIV ',iheadd
             CALL message('ReadOneBlock',ndg_mess)
             CALL finish('ReadOneBlock','wrong DIV code number')
          END IF
       END IF
       IF (linp_vor) THEN
          SELECT CASE(ndgfmt)
          CASE('cray')
             CALL cpbread(kfilev,yhead,8*8,kret)
             IF (kret==8*8) CALL util_i8toi4 (yhead(1), iheadv(1),8)
          CASE('ieee')
             READ(unit=ndunit(16),iostat=kret) iheadv
             if (kret == 0) kret = 8*8
             
          END SELECT
          IF(kret==8*8 .AND. iheadv(1)/=138) THEN
             WRITE(ndg_mess,*) 'HEADER VOR ',iheadv
             CALL message('ReadOneBlock',ndg_mess)
             CALL finish('ReadOneBlock','wrong VOR code number')
          END IF
       END IF
       IF (linp_tem .OR. linp_lnp) THEN
          SELECT CASE(ndgfmt)
          CASE('cray')
             CALL cpbread(kfilet,yhead,8*8,kret)
             IF (kret==8*8) CALL util_i8toi4 (yhead(1), iheadt(1),8)
          CASE('ieee')
             READ(unit=ndunit(17),iostat=kret) iheadt
             if (kret == 0) kret = 8*8

          END SELECT
          IF(kret==8*8 .AND. iheadt(1)/=130) THEN
             WRITE(ndg_mess,*) 'HEADER STP ',iheadt
             CALL message('ReadOneBlock',ndg_mess)
             CALL finish('ReadOneBlock','wrong STP code number')
          END IF
       END IF

       IF (kret/=8*8) THEN
          ! end of actual block reached
          CALL CloseBlock
          ! open next data block
          ndgblock = ndgblock + 1
          CALL OpenOneBlock
          CYCLE ! goto the beginning of the do-loop
       ENDIF

       ! check header consistency
       lrd_check = .TRUE.
       IF (linp_div .AND. linp_vor) THEN
          IF (.NOT. (iheadd(3)==iheadv(3) .AND. iheadd(4)==iheadv(4))) lrd_check = .FALSE.
       END IF
       IF (linp_div .AND. (linp_tem.OR.linp_lnp) ) THEN
          IF (.NOT. (iheadd(3)==iheadt(3) .AND. iheadd(4)==iheadt(4))) lrd_check = .FALSE.
       END IF
       IF (linp_vor .AND. (linp_tem.OR.linp_lnp) ) THEN
          IF (.NOT. (iheadv(3)==iheadt(3) .AND. iheadv(4)==iheadt(4))) lrd_check = .FALSE.
       END IF

       ! merge header information into IHEADD
       IF (linp_vor) THEN
          iheadd(:) = iheadv(:)
       ELSEIF (linp_tem .OR. linp_lnp) THEN
          iheadd(:) = iheadt(:)
       END IF

       ! usage of data blocks
       !
       ! lnudgpat = false --> block0,1,2,3 contains 4 time levels
       ! lnudgpat = true  --> block1,2 contains 2 time levels, block 0 used for climatology
          
       IF (lrd_check) THEN


          ! calculate corresponding time step

          IF (lnudgcli) THEN
             ! correction in climate mode
             iheadd(3) = MOD(iheadd(3),10000) + ndgblock*10000
             iday      = iymd2c(iheadd(3))
             ihead3d   = ic2ymd(iday)     ! YYMMDD
             IF (ileap == 1) THEN
                iday  = iday + 1
             ELSE IF ( (ileap == 2) .AND. (MOD(iheadd(3),10000) > 300) ) THEN
                iday  = iday + 1
             END IF
             ndgstep3 = (iday*dayl+iheadd(4)*3600)/dtime
          ELSE
             iday     = iymd2c(iheadd(3))
             ihead3d  = ic2ymd(iday)     ! YYMMDD
             ndgstep3 = ((iday-ncbase)*dayl+iheadd(4)*3600-ntbase)/dtime
          END IF
          ihead3t  = iheadd(4)*10000  ! HH0000 (hhmmss)


          IF (linp_div) THEN
             sdobs3_global(:,:,:) = 0.0

             IF (iheadd(5)*iheadd(6) /= ilen_d) &
                   CALL finish('ReadOneBlock','nudging data fault DIV, dimension mismatch')

             SELECT CASE(ndgfmt)
             CASE('cray')
                CALL pbread(kfiled,phbuf(1),ilen_d*8,kret)
                IF (kret==ilen_d*8) kret = 0
             CASE('ieee')
                READ(unit=ndunit(15),iostat=kret) phbuf(1:ilen_d)
             END SELECT
             IF (kret/=0) CALL finish('ReadOneBlock','nudging data fault DIV')

             CALL convert_input(sdobs3_global,ilev_d_min,ilev_d_max,ino_d_lev)

             IF (lnudgpat) THEN
                sdobs0(:,:,:) = 0.0

                ! read additional fields without header

                SELECT CASE(ndgfmt)
                CASE('cray')
                   CALL pbread(kfiled,phbuf(1),ilen_d*8,kret)
                   IF (kret==ilen_d*8) kret = 0
                CASE('ieee')
                   READ(unit=ndunit(15),iostat=kret) phbuf(1:ilen_d)
                END SELECT
                IF (kret/=0) CALL finish('ReadOneBlock','climate data fault DIV')

                ! the climatology

                CALL convert_input(sdobs0,ilev_d_min,ilev_d_max,ino_d_lev)

                ! read constant factor

                SELECT CASE(ndgfmt)
                CASE('cray')
                   CALL pbread(kfiled,phbuf(1),ino_d_lev*8,kret)
                   IF (kret==ino_d_lev*8) kret = 0
                CASE('ieee')
                   READ(unit=ndunit(15),iostat=kret) phbuf(1:ino_d_lev)
                END SELECT
                IF (kret/=0) CALL finish('ReadOneBlock','alpha data fault DIV')

#ifdef CRAY
                a_pat_div(ilev_d_min:ilev_d_max,4) = phbuf(1:ino_d_lev)
#else
                SELECT CASE(ndgfmt)
                CASE('cray')
                   CALL util_cray2ieee(phbuf(1),zhbuf,ino_d_lev)
                   a_pat_div(ilev_d_min:ilev_d_max,4) = zhbuf(1:ino_d_lev)
                CASE('ieee')
                   a_pat_div(ilev_d_min:ilev_d_max,4) = phbuf(1:ino_d_lev)
                END SELECT

#endif
                IF (lnudgdbx) THEN
                   WRITE(ndg_mess,'(a,40f12.5)') 'ALPHA(div)= ',a_pat_div(:,4)
                   CALL message('ReadOneBlock',ndg_mess)
                END IF
             END IF

          END IF

          IF (linp_vor) THEN
             svobs3_global(:,:,:) = 0.0

             IF (iheadv(5)*iheadv(6) /= ilen_v) &
                   CALL finish('ReadOneBlock','nudging data fault VOR, dimension mismatch')

             SELECT CASE(ndgfmt)
             CASE('cray')
                CALL pbread(kfilev,phbuf(1),ilen_v*8,kret)
                IF (kret==ilen_v*8) kret = 0
             CASE('ieee')
                READ(unit=ndunit(16),iostat=kret) phbuf(1:ilen_v)
             END SELECT
             IF (kret/=0) CALL finish('ReadOneBlock','nudging data fault VOR')

             CALL convert_input(svobs3_global,ilev_v_min,ilev_v_max,ino_v_lev)

             IF (lnudgpat) THEN
                svobs0(:,:,:) = 0.0

                ! read additional fields without header
                SELECT CASE(ndgfmt)
                CASE('cray')
                   CALL pbread(kfilev,phbuf(1),ilen_v*8,kret)
                   IF (kret==ilen_v*8) kret = 0
                CASE('ieee')
                   READ(unit=ndunit(16),iostat=kret) phbuf(1:ilen_v)
                END SELECT
                IF (kret/=0) CALL finish('ReadOneBlock','climate data fault VOR')

                ! the climatology

                CALL convert_input(svobs0,ilev_v_min,ilev_v_max,ino_v_lev)

                ! read constant factor
                SELECT CASE(ndgfmt)
                CASE('cray')
                   CALL pbread(kfilev,phbuf(1),ino_v_lev*8,kret)
                   IF (kret==ino_v_lev*8) kret = 0
                CASE('ieee')
                   READ(unit=ndunit(16),iostat=kret) phbuf(1:ino_v_lev)
                END SELECT
                IF (kret/=0) CALL finish('ReadOneBlock','alpha data fault VOR')
#ifdef CRAY
                a_pat_vor(ilev_v_min:ilev_v_max,4) = phbuf(1:ino_v_lev)
#else
                SELECT CASE(ndgfmt)
                CASE('cray')
                   CALL util_cray2ieee(phbuf(1),zhbuf,ino_v_lev)
                   a_pat_vor(ilev_v_min:ilev_v_max,4) = zhbuf(1:ino_v_lev)
                CASE('ieee')
                   a_pat_vor(ilev_v_min:ilev_v_max,4) = phbuf(1:ino_v_lev)
                END SELECT
#endif
                IF (lnudgdbx) THEN
                   WRITE(ndg_mess,'(a,40f12.5)') 'ALPHA(vor)= ',a_pat_vor(:,4)
                   CALL message('ReadOneBlock',ndg_mess)
                END IF
             END IF

          END IF

          IF (linp_tem .OR. linp_lnp) THEN
             stobs3_global(:,:,:) = 0.0

             IF (iheadt(5)*iheadt(6) /= ilen_t) &
                   CALL finish('ReadOneBlock','nudging data fault TEM/LNP, dimension mismatch')
             SELECT CASE(ndgfmt)
             CASE('cray')
                CALL pbread(kfilet,phbuf(1),ilen_t*8,kret)
                IF (kret==ilen_t*8) kret = 0
             CASE('ieee')
                READ(unit=ndunit(17),iostat=kret) phbuf(1:ilen_t)
             END SELECT
             IF (kret/=0) CALL finish('ReadOneBlock','nudging data fault TEM/LNP')

             CALL convert_input(stobs3_global,ilev_t_min,(ilev_t_min+ino_t_lev-1),ino_t_lev)

             IF (linp_lnp .AND. ino_t_lev < nlevp1) THEN
                stobs3_global(nlevp1,:,:)                 = stobs3_global(ilev_t_min+ino_t_lev-1,:,:)
                stobs3_global(ilev_t_min+ino_t_lev-1,:,:) = 0.0
             END IF


             IF (lnudgpat) THEN
                stobs0(:,:,:) = 0.0

                ! read additional fields without header
                SELECT CASE(ndgfmt)
                CASE('cray')
                   CALL pbread(kfilet,phbuf(1),ilen_t*8,kret)
                   IF (kret==ilen_t*8) kret = 0
                CASE('ieee')
                   READ(unit=ndunit(17),iostat=kret) phbuf(1:ilen_t)
                END SELECT
                IF (kret/=0) CALL finish('ReadOneBlock','climate data fault TEM/LNP')

                ! the climatology

                CALL convert_input(stobs0,ilev_t_min,(ilev_t_min+ino_t_lev-1),ino_t_lev)

                IF (linp_lnp .AND. ino_t_lev < nlevp1) THEN
                   stobs0(nlevp1,:,:)       = stobs0(ilev_t_min+ino_t_lev-1,:,:)
                   stobs0(ilev_t_min+ino_t_lev-1,:,:) = 0.0
                END IF

                ! read constant factor
                SELECT CASE(ndgfmt)
                CASE('cray')
                   CALL pbread(kfilet,phbuf(1),ino_t_lev*8,kret)
                   IF (kret==ino_t_lev*8) kret = 0
                CASE('ieee')
                   READ(unit=ndunit(17),iostat=kret) phbuf(1:ino_t_lev)
                END SELECT
                IF (kret/=0) CALL finish('ReadOneBlock','alpha data fault TEM/LNP')
#ifdef CRAY
                a_pat_tem(ilev_t_min:ilev_t_min+ino_t_lev-1,4) = phbuf(1:ino_t_lev)
#else
                SELECT CASE(ndgfmt)
                CASE('cray')
                   CALL util_cray2ieee(phbuf(1),zhbuf,ino_t_lev)
                   a_pat_tem(ilev_t_min:ilev_t_min+ino_t_lev-1,4) = zhbuf(1:ino_t_lev)
                CASE('ieee')
                   a_pat_tem(ilev_t_min:ilev_t_min+ino_t_lev-1,4) = phbuf(1:ino_t_lev)
                END SELECT
#endif
                IF (linp_lnp) THEN
                   a_pat_lnp(4) = a_pat_tem(ilev_t_min+ino_t_lev-1,4)
                   a_pat_tem(ilev_t_min+ino_t_lev-1,4) = 0.0
                   IF (lnudgdbx) THEN
                      WRITE(ndg_mess,'(a,40f12.5)') 'ALPHA(lnp)= ',a_pat_lnp(4)
                      CALL message('ReadOneBlock',ndg_mess)
                   END IF
                END IF
                IF (linp_tem) THEN
                   IF (lnudgdbx) THEN
                      WRITE(ndg_mess,'(a,40f12.5)') 'ALPHA(tem)= ',a_pat_tem(:,4)
                      CALL message('ReadOneBlock',ndg_mess)
                   END IF
                END IF

             END IF

          END IF

          ! additional calulations for pattern nudging

          IF (lnudgpat) THEN
             CALL Nudg_Init_Alpha
             
             IF (lnudgdbx) THEN
                CALL message('ReadOneBlock','ALPHA corrected')
                IF (linp_div) THEN
                   WRITE(ndg_mess,'(a,40f12.5)') 'ALPHA(div)= ',a_pat_div(:,4)
                   CALL message('ReadOneBlock',ndg_mess)
                END IF
                IF (linp_vor) THEN
                   WRITE(ndg_mess,'(a,40f12.5)') 'ALPHA(vor)= ',a_pat_vor(:,4)
                   CALL message('ReadOneBlock',ndg_mess)
                END IF
                IF (linp_tem) THEN
                   WRITE(ndg_mess,'(a,40f12.5)') 'ALPHA(tem)= ',a_pat_tem(:,4)
                   CALL message('ReadOneBlock',ndg_mess)
                END IF
                IF (linp_lnp) THEN
                   WRITE(ndg_mess,'(a,40f12.5)') 'ALPHA(lnp)= ',a_pat_lnp(4)
                   CALL message('ReadOneBlock',ndg_mess)
                END IF

             END IF

          END IF


          IF (lnudgdbx) THEN
             WRITE(ndg_mess,'(a,i8,a,i6.6,a,i10)') &
&               'new data at date= ',ihead3d,' time= ',ihead3t,' refstep= ',ndgstep3
             CALL message('ReadOneBlock',ndg_mess)
          END IF
          ! NMI filter
          IF (lnmi .AND. lnudgfrd) CALL NMI_Make(NMI_MAKE_FOD)
          EXIT ! read block OBS3 HEAD3 success

       ELSE
          CALL finish('ReadOneBlock','header synchronisation fault')
       ENDIF

    ENDDO read_records

#ifndef CRAY
    DEALLOCATE (zhbuf)
#endif
    DEALLOCATE (phbuf)

  CONTAINS

    SUBROUTINE convert_input(feld,lmin,lmax,lno)
      INTEGER :: lmin, lmax, lno, i
      REAL    :: feld(:,:,:)

#ifdef CRAY
      INTEGER :: i1, j, i2

      IF (ndgswap) CALL swap32(phbuf,lno*2*nsp)
      i1 = 0
      DO i = 1,nsp
         DO j = 1,2
            i2 = i1 + lno
            feld(lmin:lmax,j,i) = phbuf(i1+1:i2)
            i1 = i2
         END DO
      END DO
#else
      IF (ndgswap) CALL swap32(phbuf,lno*2*nsp)

      i = 2*nsp*lno
      SELECT CASE(ndgfmt)
      CASE('cray')
         CALL util_cray2ieee(phbuf(1),zhbuf,i)
         feld(lmin:lmax,:,:) = RESHAPE(zhbuf(1:i),(/lno,2,nsp/))

      CASE('ieee')
         feld(lmin:lmax,:,:) = RESHAPE(phbuf(1:i),(/lno,2,nsp/))
      END SELECT
#endif

    END SUBROUTINE convert_input

  END SUBROUTINE ReadOneBlock
!======================================================================

  SUBROUTINE OpenOneBlock
    ! open nudging data block
    INTEGER :: kret

    IF ((0 < ndgblock).AND.(ndgblock < 4)) THEN

       IF (linp_div) THEN
          WRITE(cfile,'(a5,i2.2)') 'fort.',ndunit(3*ndgblock-2)

          SELECT CASE(ndgfmt)
          CASE('cray')
             CALL pbopen(kfiled,cfile,'r',kret)
          CASE('ieee')
             ndunit(15) = ndunit(3*ndgblock-2)
             OPEN(unit=ndunit(15),file=cfile,action='read',iostat=kret,form='unformatted')
          END SELECT

          IF(kret/=0) CALL finish('OpenOneBlock','data file DIV available?')
          CALL message('OpenOneBlock','open next file for DIV (old format)')
       END IF
       IF (linp_vor) THEN
          WRITE(cfile,'(a5,i2.2)') 'fort.',ndunit(3*ndgblock-1)

          SELECT CASE(ndgfmt)
          CASE('cray')
             CALL pbopen(kfilev,cfile,'r',kret)
          CASE('ieee')
             ndunit(16) = ndunit(3*ndgblock-1)
             OPEN(unit=ndunit(16),file=cfile,action='read',iostat=kret,form='unformatted')
          END SELECT

          IF(kret/=0) CALL finish('OpenOneBlock','data file VOR available?')
          CALL message('OpenOneBlock','open next file for VOR (old format)')
       END IF
       IF (linp_tem .OR. linp_lnp) THEN
          WRITE(cfile,'(a5,i2.2)') 'fort.',ndunit(3*ndgblock)

          SELECT CASE(ndgfmt)
          CASE('cray')
             CALL pbopen(kfilet,cfile,'r',kret)
          CASE('ieee')
             ndunit(17) = ndunit(3*ndgblock)
             OPEN(unit=ndunit(17),file=cfile,action='read',iostat=kret,form='unformatted')
          END SELECT

          IF(kret/=0) CALL finish('OpenOneBlock','data file TEM available?')
          CALL message('OpenOneBlock','open next file for TEM/LNPS (old format)')
       END IF

#ifndef CRAY
       WRITE(ndg_mess,*) 'Attention unit ', &
&            ndunit(3*ndgblock-2),&
&            ndunit(3*ndgblock-1),&
&            ndunit(3*ndgblock  ),' : convert NUDGE data to IEEE'
       CALL message('OpenOneBlock',ndg_mess)
#endif

    ELSE
       CALL finish('OpenOneBlock','nudging data block number wrong')
    ENDIF

  END SUBROUTINE OpenOneBlock
!======================================================================
  SUBROUTINE CloseBlock

    ! close nudging data block
    INTEGER  :: kret
    SELECT CASE(ndgfmt)
    CASE('cray')
       IF (linp_div)               CALL pbclose(kfiled,kret)
       IF (linp_vor)               CALL pbclose(kfilev,kret)
       IF (linp_tem .OR. linp_lnp) CALL pbclose(kfilet,kret)
    CASE('ieee')
       IF (linp_div)               CLOSE(ndunit(15),iostat=kret)
       IF (linp_vor)               CLOSE(ndunit(16),iostat=kret)
       IF (linp_tem .OR. linp_lnp) CLOSE(ndunit(17),iostat=kret)
    END SELECT
  END SUBROUTINE CloseBlock

!======================================================================
!
! I/O SST DATA
!
!======================================================================

  SUBROUTINE NudgingReadSST
    ! Read ECHAM SST for nudging experiments
    ! call every time step in time step loop
    !
    ! Local scalars 
    INTEGER  :: idx, krtim, iday, id, im, iy, kret, jr, isec, ihms,&
         iheads_need, ihead_read

    ! Local arrays
    REAL, ALLOCATABLE :: zhbuf(:), phbuf(:,:)
    INTEGER       :: ihead(8)
    CHARACTER (8) :: yhead(8)

    REAL, POINTER :: sstn_global(:,:)

    ! Intrinsic functions
    INTRINSIC MOD

    ! Executable statements

    IF (nsstinc==0) RETURN

    ! get actually date/time of NSTEP
    iday = ncbase + (ntbase+dtime*nstep)/dayl + 0.01
    CALL cd2dat(iday,id,im,iy)
    isec = MOD( (ntbase+dtime*nstep) ,dayl)
    ihms = isec2hms(isec)

    ! find actually sst /date/time
    krtim = nsstoff + 24  ! in hours of the day
    DO
       krtim = krtim - nsstinc
       IF (krtim*10000 <= ihms) EXIT
    END DO
    IF (krtim < 0) THEN
       krtim = krtim + 24
       iday = (ncbase-1) + (ntbase+dtime*nstep)/dayl + 0.01
       CALL cd2dat(iday,id,im,iy)
    END IF

    iheads_need = iy*1000000 + im*10000 + id*100 + krtim
    iheads_need = MOD(iheads_need,100000000)    ! remove century


    lsstn = .FALSE.
    IF (sstblock<0) THEN


       ! call at first time, no initialization before
       sstblock = 1
       
       IF (ioflag) THEN
          WRITE(cfile,'(a5,i2.2)') 'fort.',ndunit(9+sstblock)
          SELECT CASE(ndgfmt)
          CASE('cray')
             CALL pbopen(kfiles,cfile,'r',kret)
          CASE('ieee')
             ndunit(18) = ndunit(9+sstblock)
             OPEN(unit=ndunit(18),file=cfile,action='read',iostat=kret,form='unformatted')
          END SELECT
          IF (kret/=0) CALL finish('NudgingReadSST','nudging SST files available?')
       END IF
       ipos   = 0
       iheads = -99
       lsstn  = .TRUE.

    ELSE IF (iheads < iheads_need) THEN
       ! compare with last record read from sst file
       lsstn = .TRUE.
    ENDIF

    IF (lsstn) THEN

       IF (ioflag) THEN

          ALLOCATE(sstn_global(nlon,ngl)) ; sstn_global(:,:) = 0.
          ALLOCATE(phbuf(nlon,ngl));        phbuf(:,:) = 0.0

          ! search next sst data record
          read_sst_loop : DO

             SELECT CASE(ndgfmt)
             CASE('cray')
                CALL cpbread(kfiles,yhead,8*8,kret)
                IF(kret == 8*8) kret = 0
             CASE('ieee')
                READ(unit=ndunit(18),iostat=kret) ihead
             END SELECT
             IF (kret/=0) THEN
                ! open next SST data file
                sstblock = sstblock+1
                IF (sstblock>3) CALL finish ('NudgingReadSST','need more sst files')
                
                WRITE(cfile,'(a5,i2.2)') 'fort.',ndunit(9+sstblock)
                SELECT CASE(ndgfmt)
                CASE('cray')
                   CALL pbclose(kfiles,kret)
                   CALL pbopen(kfiles,cfile,'r',kret)
                CASE('ieee')
                   CLOSE(unit=ndunit(18),iostat=kret)
                   ndunit(18) = ndunit(9+sstblock)
                   OPEN(unit=ndunit(18),file=cfile,action='read',iostat=kret,form='unformatted')
                END SELECT

                WRITE (ndg_mess,*) 'open next SST data file ',sstblock,ndunit(9+sstblock)
                CALL message('NudgingReadSST',ndg_mess)
                ipos = 0
                CYCLE
             ENDIF

             ! check header, remove century
             SELECT CASE(ndgfmt)
             CASE('cray')
                CALL util_i8toi4(yhead(1), ihead(1), 8)
             END SELECT

             IF(ihead(1)/=139) THEN
                WRITE(ndg_mess,*) 'HEADER SST ',ihead
                CALL message('ReadOneBlock',ndg_mess)
                CALL finish('NudgingReadSST','wrong SST code number')
             END IF
             IF( (ihead(5)/=nlon) .OR. (ihead(6)/=ngl)) THEN
                WRITE(ndg_mess,*) 'HEADER SST ',ihead
                CALL message('ReadOneBlock',ndg_mess)
                CALL finish('NudgingReadSST','SST dimension missmatch')
             END IF

             ihead(3) = MOD(ihead(3),1000000)

             ihead_read = ihead(3)*100+ihead(4)
             IF (ihead_read == iheads_need) EXIT
             IF (ihead_read > iheads_need ) THEN
                WRITE(ndg_mess,*) 'WARNING: HEADER SST ',ihead
                CALL message('ReadOneBlock',ndg_mess)
                CALL message('ReadOneBlock','use first SST record')
                EXIT
             ENDIF
             IF (iheads > iheads_need) CALL finish('NudgingReadSST','sst date fault')

             ! skip data set
             SELECT CASE(ndgfmt)
             CASE('cray')
                ipos = ipos + 8 + nlon*ngl
                CALL pbseek(kfiles,ipos*8,0,kret)
             CASE('ieee')
                READ(unit=ndunit(18),iostat=kret) phbuf
             END SELECT

             WRITE (ndg_mess,*) 'skip record ',ihead
             CALL message('NudgingReadSST',ndg_mess)

          ENDDO read_sst_loop

          ipos = ipos + 8 + nlon*ngl
          WRITE (ndg_mess,*) 'use SST record ',ihead
          CALL message('NudgingReadSST',ndg_mess)
          iheads = iheads_need

          ! read new sst field, north -> south

          SELECT CASE(ndgfmt)
          CASE('cray')

             ALLOCATE(zhbuf(nlon*ngl));  zhbuf(:) = 0.0
             CALL pbread(kfiles,zhbuf(1),nlon*ngl*8,kret)
             IF (ndgswap) CALL swap32(zhbuf,nlon*ngl)
#ifndef CRAY
             CALL message('NudgingReadSST',' Attention convert SST data to IEEE')
             CALL util_cray2ieee(zhbuf,sstn_global(1,1),nlon*ngl)
#else
             sstn_global(:,:)= RESHAPE(zhbuf(:),(/nlon,ngl/))
#endif
             DEALLOCATE (zhbuf)

          CASE ('ieee')
             READ(unit=ndunit(18),iostat=kret) sstn_global

          END SELECT

          DEALLOCATE (phbuf)

       ENDIF

       CALL scatter_gp(sstn_global,sstn,global_decomposition)

       IF (p_parallel) CALL p_bcast(iheads, p_io)

       IF (ioflag) DEALLOCATE(sstn_global)

    END IF

  END SUBROUTINE NudgingReadSST
!======================================================================

  SUBROUTINE NudgingSSTnew

    !fu+ USE mo_couple,        ONLY: ssto, bzo
    !
    ! call every time step in latitude loop
    !
    !-------------------------------------------------------
    ! Read NMC-sea surface temperature analysis retrieved
    ! from the mars archive, instead of the climatology provided
    ! for ECHAM. SST's are available every 24 hours
    !--------------------------------------------------------
    !

    ! Local scalars
    INTEGER          :: jrow, jn
    REAL, PARAMETER  :: zdt=0.01  ! correct temperature near freezing point
    REAL             :: zts

    ! Intrinsic functions
    INTRINSIC MAX, MIN

    ! Executable statements
    IF (nsstinc==0) THEN       ! use the standard sst for nudging
       write(nout,*) "don't use NCEP SST to nudge!!"
       !fu++CALL echam_sst

    ELSE
       ! update sea surface temperatures at every time step
       jrow = nrow(2)  ! north -> south local index

       DO jn = 1,local_decomposition%nglon

          zts = sstn(jn,jrow)
          IF (slmm(jn,jrow)<=0.5) THEN             ! sea point
             IF (zts<=ndg_freez) THEN                ! below freezing level
                tsm(jn,jrow)  =MIN(zts,ctfreez-zdt)
                tsm1m(jn,jrow)=tsm(jn,jrow)
             ELSE                                  ! above freezing level
                tsm(jn,jrow)  =MAX(zts,ctfreez+zdt)
                tsm1m(jn,jrow)=tsm(jn,jrow)
             ENDIF
          ENDIF

       ENDDO

       !fu+IF (lcouple) THEN
       !   ! merge with ocean-model SST for bzo=1 fu++
       !   DO jn=1,local_decomposition%nglon
       !      IF ( (bzo(jn,jrow,0) .GT. 0.8) .AND.&
       !           (bzo(jn,jrow,0) .LT. 1.5) ) THEN   !over ocean
       !         tsm(jn,jrow)   = ssto(jn,jrow,0)+273.16
       !         tsm1m(jn,jrow) = tsm(jn,jrow)
       !      END IF
       !   END DO
       !fu+END IF

       IF (lsstn) THEN
          ! new sst field were read at this timestep
          ! correction of seaice skin-temperature
          auxil1m(:,jrow)=tsm(:,jrow)
          auxil2m(:,jrow)=tsm(:,jrow)
          IF ( (lnudgdbx) .AND. (jrow==local_decomposition%nglat)) THEN
             WRITE(ndg_mess,*) &
&               'SEAICE correction at NSTEP= ',nstep
             CALL message('NudgingSSTnew',ndg_mess)
          END IF
       END IF

    ENDIF

  !fu++CONTAINS
    !SUBROUTINE echam_sst
      !USE mo_sst, ONLY: clsst, clsst2

      !IF (lamip2) THEN;       CALL clsst2
      !fu++ELSE IF (lcouple) THEN; CALL cplsst
      !ELSE;                   CALL clsst
      !END IF
    !fu++END SUBROUTINE echam_sst
  END SUBROUTINE NudgingSSTnew

!======================================================================
!
! MODEL OUTPUT RESIDUE TERMS
!
!======================================================================

  SUBROUTINE NudgingOut
    ! Write out instantaneous (OUTTINS)
    ! and accumulated (OUTTACC) tendencies

    REAL    :: tfact, tfactsite
    INTEGER :: ierr, iret
    REAL    :: worksp(1,2,local_decomposition%snsp)

    ! define GRIB block 1
!    ksec1(1) = nudging_table
    ksec1(1) = local_table

    CALL set_output_time

    ksec1(7) = 109; level_type = ksec1(7)

    ksec1(10) = year
    ksec1(11) = month
    ksec1(12) = day
    ksec1(13) = hour
    ksec1(14) = minute
    ksec1(21) = century

    ksec4(1) = n2sp

    IF (ioflag) THEN
       WRITE (ndg_mess,'(a,i2.2,a1,i2.2,2x,i2.2,a1,i2.2,a1,i2.2,i2.2)') &
&        'store data at ...  ',         &
&        hour, ':', minute, day, '.', month, '.', century-1, year
       CALL message('NudgingOut',ndg_mess)
    END IF

    IF (ltdiag) THEN
       WRITE(ndunit(14),'(a,a)') '###',TRIM(ndg_mess)
       CALL Nudg_Correl
    END IF
    ! **** store only nudging part

    ! **** write instantaneous values
    IF (linp_lnp .AND. lppp) THEN    ! Pressure
       code_parameter = ndgcode(1);   ksec1(6) = code_parameter
       level_p2 = 0;                  ksec1(8) = level_p2
       worksp(1,:,:) = flagn(nlevp1,:,:)*stten(nlevp1,:,:) 
       CALL NudgStoreSP
    ENDIF
    IF (linp_tem .AND. lppt) THEN    ! Temperature
       code_parameter = ndgcode(2);   ksec1(6) = code_parameter
       DO level_p2 = 1, nlev;         ksec1(8) = level_p2
          worksp(1,:,:) = flagn(level_p2,:,:)*stten(level_p2,:,:)
          CALL NudgStoreSP
       END DO
    END IF
    IF (linp_div .AND. lppd) THEN    ! Divergence
       code_parameter = ndgcode(3);   ksec1(6) = code_parameter
       DO level_p2 = 1, nlev;         ksec1(8) = level_p2
          worksp(1,:,:) = flagn(level_p2,:,:)*sdten(level_p2,:,:)
          CALL NudgStoreSP
       END DO
    END IF
    IF (linp_vor .AND. lppvo) THEN    ! Vorticity
       code_parameter = ndgcode(4);   ksec1(6) = code_parameter
       DO level_p2 = 1, nlev;         ksec1(8) = level_p2
          worksp(1,:,:) = flagn(level_p2,:,:)*svten(level_p2,:,:)
          CALL NudgStoreSP
       END DO
    END IF

    ! **** accumulated data

    ! **** proportionality factor, output given in VALUE/sec
    IF (ioflag ) THEN
       IF (time_inc_steps(nptime,TIME_INC_DAYS) /= iaccu) THEN
          WRITE(ndg_mess,*) 'first accumulation done, No. of steps =',iaccu
          CALL message('NudgingOut',ndg_mess)
       END IF
    END IF

    tfact = 1.0/iaccu
    IF (lsite .AND. isiteaccu > 0) THEN
       tfactsite = 1.0/isiteaccu
    ELSE
       tfactsite = 1.0
    END IF

    IF (lnudgdbx) THEN
       WRITE(ndg_mess,*) 'correct accumulated data with = ',tfact
       CALL message('NudgingOut',ndg_mess)
    END IF

    IF (linp_lnp .AND. lppp) THEN    ! Pressure
       code_parameter = ndgcode(5);   ksec1(6) = code_parameter
       level_p2 = 0;                  ksec1(8) = level_p2
       worksp(1,:,:) = flagn(nlevp1,:,:)*sttac(nlevp1,:,:)*tfact
       CALL NudgStoreSP

       IF (lsite) THEN
          code_parameter = ndgcode(29);   ksec1(6) = code_parameter
          worksp(1,:,:) = stsite(nlevp1,:,:)*tfactsite
          CALL NudgStoreSP
       END IF
    ENDIF
    IF (linp_tem .AND. lppt) THEN    ! Temperature
       code_parameter = ndgcode(6);   ksec1(6) = code_parameter
       DO level_p2 = 1, nlev;         ksec1(8) = level_p2
          worksp(1,:,:) = flagn(level_p2,:,:)*sttac(level_p2,:,:)*tfact
          CALL NudgStoreSP
       END DO

       IF (lsite) THEN
          code_parameter = ndgcode(30);  ksec1(6) = code_parameter
          DO level_p2 = 1, nlev;         ksec1(8) = level_p2
             worksp(1,:,:) = stsite(level_p2,:,:)*tfactsite
             CALL NudgStoreSP
          END DO
       END IF
    END IF

    IF (linp_div .AND. lppd) THEN    ! Divergence
       code_parameter = ndgcode(7);   ksec1(6) = code_parameter
       DO level_p2 = 1, nlev;         ksec1(8) = level_p2
          worksp(1,:,:) = flagn(level_p2,:,:)*sdtac(level_p2,:,:)*tfact
          CALL NudgStoreSP
       END DO

       IF (lsite) THEN
          code_parameter = ndgcode(31);  ksec1(6) = code_parameter
          DO level_p2 = 1, nlev;         ksec1(8) = level_p2
             worksp(1,:,:) = sdsite(level_p2,:,:)*tfactsite
             CALL NudgStoreSP
          END DO
       END IF
    END IF

    IF (linp_vor .AND. lppvo) THEN    ! Vorticity
       code_parameter = ndgcode(8);   ksec1(6) = code_parameter
       DO level_p2 = 1, nlev;         ksec1(8) = level_p2
          worksp(1,:,:) = flagn(level_p2,:,:)*svtac(level_p2,:,:)*tfact
          CALL NudgStoreSP
       END DO

       IF (lsite) THEN
          code_parameter = ndgcode(32);  ksec1(6) = code_parameter
          DO level_p2 = 1, nlev;         ksec1(8) = level_p2
             worksp(1,:,:) = svsite(level_p2,:,:)*tfactsite
             CALL NudgStoreSP
          END DO
       END IF
    END IF

    IF (lnudgwobs) THEN       ! store diagnostic part

       ! ***** write instantaneous values
       IF (linp_lnp .AND. lppp) THEN       ! Pressure
          code_parameter = ndgcode(9);    ksec1(6) = code_parameter
          level_p2 = 0;                   ksec1(8) = level_p2
          worksp(1,:,:) = flago(nlevp1,:,:)*stten(nlevp1,:,:) 
          CALL NudgStoreSP
       ENDIF
       IF (linp_tem .AND. lppt) THEN       ! Temperature
          code_parameter = ndgcode(10);    ksec1(6) = code_parameter
          DO level_p2 = 1, nlev;           ksec1(8) = level_p2
             worksp(1,:,:) = flago(level_p2,:,:)*stten(level_p2,:,:)
             CALL NudgStoreSP
          END DO
       END IF
       IF (linp_div .AND. lppd) THEN       ! Divergence
          code_parameter = ndgcode(11);    ksec1(6) = code_parameter
          DO level_p2 = 1, nlev;           ksec1(8) = level_p2
             worksp(1,:,:) = flago(level_p2,:,:)*sdten(level_p2,:,:)
             CALL NudgStoreSP
          END DO
       END IF
       IF (linp_vor .AND. lppvo) THEN       ! Vorticity
          code_parameter = ndgcode(12);    ksec1(6) = code_parameter
          DO level_p2 = 1, nlev;           ksec1(8) = level_p2
             worksp(1,:,:) = flago(level_p2,:,:)*svten(level_p2,:,:)
             CALL NudgStoreSP
          END DO
       END IF

       ! **** accumulated data
       IF (linp_lnp .AND. lppp) THEN       ! Pressure
          code_parameter = ndgcode(13);    ksec1(6) = code_parameter
          level_p2 = 0;                    ksec1(8) = level_p2
          worksp(1,:,:) = flago(nlevp1,:,:)*sttac(nlevp1,:,:)*tfact
          CALL NudgStoreSP
       ENDIF
       IF (linp_tem .AND. lppt) THEN       ! Temperature
          code_parameter = ndgcode(14);    ksec1(6) = code_parameter
          DO level_p2 = 1, nlev;           ksec1(8) = level_p2
             worksp(1,:,:) = flago(level_p2,:,:)*sttac(level_p2,:,:)*tfact
             CALL NudgStoreSP
          END DO
       END IF
       IF (linp_div .AND. lppd) THEN       ! Divergence
          code_parameter = ndgcode(15);    ksec1(6) = code_parameter
          DO level_p2 = 1, nlev;           ksec1(8) = level_p2
             worksp(1,:,:) = flago(level_p2,:,:)*sdtac(level_p2,:,:)*tfact
             CALL NudgStoreSP
          END DO
       END IF
       IF (linp_vor .AND. lppvo) THEN       ! Vorticity
          code_parameter = ndgcode(16);    ksec1(6) = code_parameter
          DO level_p2 = 1, nlev;           ksec1(8) = level_p2
             worksp(1,:,:) = flago(level_p2,:,:)*svtac(level_p2,:,:)*tfact
             CALL NudgStoreSP
          END DO
       END IF

       ! ***** write observations only instantaneous values
       IF (linp_lnp .AND. lppp) THEN       ! Pressure
          code_parameter = ndgcode(17);    ksec1(6) = code_parameter
          level_p2 = 0;                    ksec1(8) = level_p2
          worksp(1,:,:) = stobs(nlevp1,:,:) 
          CALL NudgStoreSP
       ENDIF
       IF (linp_tem .AND. lppt) THEN       ! Temperature
          code_parameter = ndgcode(18);    ksec1(6) = code_parameter
          DO level_p2 = 1, nlev;           ksec1(8) = level_p2
             worksp(1,:,:) = stobs(level_p2,:,:)
             CALL NudgStoreSP
          END DO
       END IF
       IF (linp_div .AND. lppd) THEN       ! Divergence
          code_parameter = ndgcode(19);    ksec1(6) = code_parameter
          DO level_p2 = 1, nlev;           ksec1(8) = level_p2
             worksp(1,:,:) = sdobs(level_p2,:,:)
             CALL NudgStoreSP
          END DO
       END IF
       IF (linp_vor .AND. lppvo) THEN       ! Vorticity
          code_parameter = ndgcode(20);    ksec1(6) = code_parameter
          DO level_p2 = 1, nlev;           ksec1(8) = level_p2
             worksp(1,:,:) = svobs(level_p2,:,:)
             CALL NudgStoreSP
          END DO
       END IF

    END IF

    ! store fast mode part
    IF (lnmi .AND. ifast_accu>0) THEN
       ! rescale the factor
       tfact = 1/(ifast_accu*twodt)
       IF (linp_lnp .AND. lppp) THEN       ! Pressure
          code_parameter = ndgcode(21);    ksec1(6) = code_parameter
          level_p2 = 0;                    ksec1(8) = level_p2
          worksp(1,:,:) = flagn(nlevp1,:,:)*stfast_accu(nlevp1,:,:)*tfact
          CALL NudgStoreSP
       ENDIF
       IF (linp_tem .AND. lppt) THEN       ! Temperature
          code_parameter = ndgcode(22);    ksec1(6) = code_parameter
          DO level_p2 = 1, nlev;           ksec1(8) = level_p2
             worksp(1,:,:) = flagn(level_p2,:,:)*stfast_accu(level_p2,:,:)*tfact
             CALL NudgStoreSP
          END DO
       END IF
       IF (linp_div .AND. lppd) THEN       ! Divergence
          code_parameter = ndgcode(23);    ksec1(6) = code_parameter
          DO level_p2 = 1, nlev;           ksec1(8) = level_p2
             worksp(1,:,:) = flagn(level_p2,:,:)*sdfast_accu(level_p2,:,:)*tfact
             CALL NudgStoreSP
          END DO
       END IF
       IF (linp_vor .AND. lppvo) THEN       ! Vorticity
          code_parameter = ndgcode(24);    ksec1(6) = code_parameter
          DO level_p2 = 1, nlev;           ksec1(8) = level_p2
             worksp(1,:,:) = flagn(level_p2,:,:)*svfast_accu(level_p2,:,:)*tfact
             CALL NudgStoreSP
          END DO
       END IF
    END IF


    ! store residue correction term
    IF (lrescor_a) THEN
       IF (linp_lnp .AND. lppp) THEN       ! Pressure
          code_parameter = ndgcode(25);    ksec1(6) = code_parameter
          level_p2 = 0;                    ksec1(8) = level_p2
          worksp(1,:,:) = flagn(nlevp1,:,:)*(stres_a(nlevp1,:,:)+stres_b(nlevp1,:,:))
          CALL NudgStoreSP
       ENDIF
       IF (linp_tem .AND. lppt) THEN       ! Temperature
          code_parameter = ndgcode(26);    ksec1(6) = code_parameter
          DO level_p2 = 1, nlev;           ksec1(8) = level_p2
             worksp(1,:,:) = flagn(level_p2,:,:)*(stres_a(level_p2,:,:)+stres_b(level_p2,:,:))
             CALL NudgStoreSP
          END DO
       END IF
       IF (linp_div .AND. lppd) THEN       ! Divergence
          code_parameter = ndgcode(27);    ksec1(6) = code_parameter
          DO level_p2 = 1, nlev;           ksec1(8) = level_p2
             worksp(1,:,:) = flagn(level_p2,:,:)*(sdres_a(level_p2,:,:)+sdres_b(level_p2,:,:))
             CALL NudgStoreSP
          END DO
       END IF
       IF (linp_vor .AND. lppvo) THEN       ! Vorticity
          code_parameter = ndgcode(28);    ksec1(6) = code_parameter
          DO level_p2 = 1, nlev;           ksec1(8) = level_p2
             worksp(1,:,:) = flagn(level_p2,:,:)*(svres_a(level_p2,:,:)+svres_b(level_p2,:,:))
             CALL NudgStoreSP
          END DO
       END IF
    END IF

    CALL Nudge_ResidueStore

    ! reset accumulation memory
    sttac(:,:,:) = 0.0
    sdtac(:,:,:) = 0.0
    svtac(:,:,:) = 0.0

    IF (lsite) THEN
       stsite(:,:,:) = 0.0
       sdsite(:,:,:) = 0.0
       svsite(:,:,:) = 0.0
       isiteaccu = 0
    END IF

    iaccu = 0

    IF (lnmi) THEN
       sdfast_accu(:,:,:) = 0.0
       svfast_accu(:,:,:) = 0.0
       stfast_accu(:,:,:) = 0.0
       ifast_accu = 0
    END IF

    CONTAINS

      SUBROUTINE NudgStoreSP
        ! External subroutines
        EXTERNAL codegb5, pbwrite

        CALL gather_sp(worksp_global,worksp,global_decomposition)

        IF (ioflag) THEN

#ifdef EMOS
           CALL gribex (ksec0, ksec1, ksec2_sp, psec2, ksec3, psec3, &
&                   ksec4, worksp_global, n2sp, kgrib, kleng, kword, 'C', ierr)
#else
           CALL codegb5 (worksp_global,n2sp,16,nbit,ksec1,ksec2_sp,vct,2*nlevp1, &
&                    kgrib,klengo,kword,0,ierr)
#endif
           CALL pbwrite(nunitdf,kgrib,kword*iobyte,iret)

           IF (iret /= kword*iobyte) &
&             CALL finish('NudgeStoreSP', &
&             'I/O error on spectral harmonics output - disk full?')

        END IF

      END SUBROUTINE NudgStoreSP

  END SUBROUTINE NudgingOut
!======================================================================

  SUBROUTINE NudgingRerun(mode)
    ! store and restore accumulated fields for nudging
    ! the data format of rerun files is maschine dependend

    INTEGER, INTENT(in) :: mode
    INTEGER :: iunit, iistep, iinsp, iinlev
    LOGICAL :: found

    REAL, POINTER :: sp_global(:,:,:), sp2_global(:,:,:)

    IF (ioflag) THEN
       ALLOCATE(sp_global(nlevp1,2,nsp))
       sp2_global => sp_global(1:nlev,:,:)
    END IF

    iunit = ndunit(13)

    SELECT CASE(mode)

    CASE(NDG_RERUN_WR)  ! store restart data

       IF (ioflag) THEN
          WRITE(cfile,'(a5,i2.2)') 'fort.',iunit
          OPEN(iunit,file=cfile,form='unformatted')
          WRITE(iunit) nstep+1,nsp,nlev
       END IF

       CALL gather_sp (sp2_global, sdtac, global_decomposition)
       IF (ioflag) WRITE(iunit) sp2_global ! sdtac

       CALL gather_sp (sp2_global, svtac, global_decomposition)
       IF (ioflag) WRITE(iunit) sp2_global ! svtac

       CALL gather_sp (sp_global,  sttac, global_decomposition)
       IF (ioflag) WRITE(iunit) sp_global  ! sttac

       IF (lsite) THEN ! not working parallel
          WRITE(iunit) isiteaccu
          WRITE(iunit) sdsite
          WRITE(iunit) svsite
          WRITE(iunit) stsite
       END IF

       ! store the residue correction terms
       IF (ioflag) WRITE(iunit) iaccu, lrescor_a, lrescor_b

       CALL gather_sp (sp2_global, sdres_a, global_decomposition)
       IF (ioflag) WRITE(iunit) sp2_global ! sdres_a

       CALL gather_sp (sp2_global, svres_a, global_decomposition)
       IF (ioflag) WRITE(iunit) sp2_global ! svres_a

       CALL gather_sp (sp_global,  stres_a, global_decomposition)
       IF (ioflag) WRITE(iunit) sp_global  ! stres_a

       CALL gather_sp (sp2_global, sdres_b, global_decomposition)
       IF (ioflag) WRITE(iunit) sp2_global ! sdres_b

       CALL gather_sp (sp2_global, svres_b, global_decomposition)
       IF (ioflag) WRITE(iunit) sp2_global ! svres_b

       CALL gather_sp (sp_global,  stres_b, global_decomposition)
       IF (ioflag) WRITE(iunit) sp_global  ! stres_b

       ! store fast mode buffer state
       IF (lnmi) THEN ! not working in parallel
          WRITE(iunit) lfill_a, lfill_b, ifast_accu
          WRITE(iunit) sdfast_a
          WRITE(iunit) svfast_a
          WRITE(iunit) stfast_a
          WRITE(iunit) sdfast_b
          WRITE(iunit) svfast_b
          WRITE(iunit) stfast_b
          WRITE(iunit) sdfast_accu
          WRITE(iunit) svfast_accu
          WRITE(iunit) stfast_accu
       END IF
       IF (ioflag) THEN
          WRITE(ndg_mess,*) 'store accu-tend at NSTEP+1 = ',nstep+1,' unit= ',iunit
          CALL message('NudgingRerun',ndg_mess)
          CLOSE(iunit)
       END IF

    CASE(NDG_RERUN_RD)  ! reload restart data
       sdtac(:,:,:) = 0.0
       svtac(:,:,:) = 0.0
       sttac(:,:,:) = 0.0

       IF (ioflag) THEN
          INQUIRE(iunit,exist=found)
          IF (found) THEN
             REWIND(iunit, err=100)
             READ(iunit, err=100, END=100) iistep,iinsp,iinlev
             IF ( (iinsp/=nsp).OR.(iinlev/=nlev) ) THEN
                WRITE(ndg_mess,*) 'WARNING: dimension mismatch in nudging data rerunfile'
                CALL message('NudgingRerun',ndg_mess)
                GOTO 100
             END IF
          ELSE
             CALL message('NudgingRerun','missing nudging rerun data')
             GOTO 100
          END IF
       END IF
       IF (p_parallel) THEN
          CALL p_bcast(iistep, p_io)
          CALL p_bcast(iinsp,  p_io)
          CALL p_bcast(iinlev, p_io)
       END IF

       IF (ioflag) READ(iunit) sp2_global ! sdtac
       CALL scatter_sp(sp2_global, sdtac, global_decomposition)

       IF (ioflag) READ(iunit) sp2_global ! svtac
       CALL scatter_sp(sp2_global, svtac, global_decomposition)

       IF (ioflag) READ(iunit) sp_global  ! sttac
       CALL scatter_sp(sp_global,  sttac, global_decomposition)

       IF (lsite) THEN ! works not in parallel mode
          READ(iunit) isiteaccu
          READ(iunit) sdsite
          READ(iunit) svsite
          READ(iunit) stsite
       END IF

       ! restore the residue correction terms
       IF (ioflag) READ(iunit) iaccu, lrescor_a, lrescor_b
       IF (p_parallel) THEN
          CALL p_bcast(iaccu, p_io)
          CALL p_bcast(lrescor_a, p_io)
          CALL p_bcast(lrescor_b, p_io)
       END IF

       IF (ioflag) READ(iunit) sp2_global ! sdres_a
       CALL scatter_sp (sp2_global, sdres_a, global_decomposition)

       IF (ioflag) READ(iunit) sp2_global ! svres_a
       CALL scatter_sp (sp2_global, svres_a, global_decomposition)

       IF (ioflag) READ(iunit) sp_global  ! stres_a
       CALL scatter_sp (sp_global,  stres_a, global_decomposition)


       IF (ioflag) READ(iunit) sp2_global ! sdres_b
       CALL scatter_sp (sp2_global, sdres_b, global_decomposition)

       IF (ioflag) READ(iunit) sp2_global ! svres_b
       CALL scatter_sp (sp2_global, svres_b, global_decomposition)

       IF (ioflag) READ(iunit) sp_global  ! stres_b
       CALL scatter_sp (sp_global,  stres_b, global_decomposition)

       ! restore fast mode buffer state
       IF (lnmi) THEN ! works not in parallel mode
          READ(iunit) lfill_a, lfill_b, ifast_accu
          READ(iunit) sdfast_a
          READ(iunit) svfast_a
          READ(iunit) stfast_a
          READ(iunit) sdfast_b
          READ(iunit) svfast_b
          READ(iunit) stfast_b
          READ(iunit) sdfast_accu
          READ(iunit) svfast_accu
          READ(iunit) stfast_accu
       END IF

       IF (ioflag) THEN
          WRITE(ndg_mess,*) 'read data at RerunSTEP= ',iistep,&
&            ' model NSTEP=',nstep,' unit= ',iunit
          CALL message('NudgingRerun',ndg_mess)
          CLOSE(iunit)
       END IF

    CASE default
       WRITE(ndg_mess,*) 'transfer mode (',mode,') not implemented'
       CALL finish('NudgingRerun',ndg_mess)
    END SELECT

100 CONTINUE

  END SUBROUTINE NudgingRerun

!======================================================================
!
! UTILITIES SECTION
!
!======================================================================

  SUBROUTINE Nudg_Norm(a,b,no_w1,no_sp,nab)
    REAL      :: a(:,:), b(:,:)
    INTEGER   :: no_w1      ! number of coefficients for first wavenumber
    INTEGER   :: no_sp      ! total number of spectralcoefficients
    REAL      :: nab        ! norm  in spectralspace
    INTEGER :: i
    nab = 0.0
    DO i=1,no_w1
       nab = nab + a(1,i)*b(1,i) + a(2,i)*b(2,i)
    END DO
    DO i=no_w1+1,no_sp
       nab = nab + 2.0*( a(1,i)*b(1,i) + a(2,i)*b(2,i) )
    END DO

  END SUBROUTINE Nudg_Norm

  SUBROUTINE Nudg_Correl
    ! correlations between the nudging term and the tendency diagnostic terms
    INTEGER :: jk, jl, js
    REAL :: sum_ab, sum_aa, sum_bb, a_real, a_imag, weight(nsp), b_real, b_imag
    REAL :: cc_tem(ndtem), cc_vor(ndvor), cc_div(nddiv), cc_prs(ndprs)

    weight(1)          = 0.0
    weight(2:nnp1)     = 1.0
    weight(nnp1+1:nsp) = 2.0

    ! divergence equation
    DO jl=1,nlev
       sum_bb = 0.0
       DO js=2,nsp
          b_real = flagn(jl,1,js)*sdtac(jl,1,js)
          b_imag = flagn(jl,2,js)*sdtac(jl,2,js)
          sum_bb = sum_bb + weight(js)*(b_real*b_real + b_imag*b_imag)
       END DO
       DO jk=1,nddiv
          DO js=2,nsp
             sum_ab = 0.0
             sum_aa = 0.0
             a_real = pddiv(jl,1,js,jk)
             a_imag = pddiv(jl,2,js,jk)
             sum_aa = sum_aa + weight(js)*(a_real*a_real + a_imag*a_imag)
             b_real = flagn(jl,1,js)*sdtac(jl,1,js)
             b_imag = flagn(jl,2,js)*sdtac(jl,2,js)
             sum_ab = sum_ab + weight(js)*(a_real*b_real + a_imag*b_imag)
          END DO
          IF (sum_aa > 0.0 .AND. sum_bb > 0.0) THEN
             cc_div(jk) = sum_ab/SQRT(sum_aa*sum_bb)
          ELSE
             cc_div(jk) = 0.0
          END IF
       END DO
       WRITE(ndunit(14),'(a,i3,20(1x,f7.3))') 'DIV_L',jl,cc_div(:)
    END DO

    ! vorticity equation
    DO jl=1,nlev
       sum_bb = 0.0
       DO js=2,nsp
          b_real = flagn(jl,1,js)*svtac(jl,1,js)
          b_imag = flagn(jl,2,js)*svtac(jl,2,js)
          sum_bb = sum_bb + weight(js)*(b_real*b_real + b_imag*b_imag)
       END DO
       DO jk=1,ndvor
          DO js=2,nsp
             sum_ab = 0.0
             sum_aa = 0.0
             a_real = pdvor(jl,1,js,jk)
             a_imag = pdvor(jl,2,js,jk)
             sum_aa = sum_aa + weight(js)*(a_real*a_real + a_imag*a_imag)
             b_real = flagn(jl,1,js)*svtac(jl,1,js)
             b_imag = flagn(jl,2,js)*svtac(jl,2,js)
             sum_ab = sum_ab + weight(js)*(a_real*b_real + a_imag*b_imag)
          END DO
          IF (sum_aa > 0.0 .AND. sum_bb > 0.0) THEN
             cc_vor(jk) = sum_ab/SQRT(sum_aa*sum_bb)
          ELSE
             cc_vor(jk) = 0.0
          END IF
       END DO
       WRITE(ndunit(14),'(a,i3,20(1x,f7.3))') 'VOR_L',jl,cc_vor(:)
    END DO

    ! temperatur equation
    DO jl=1,nlev
       sum_bb = 0.0
       DO js=2,nsp
          b_real = flagn(jl,1,js)*sttac(jl,1,js)
          b_imag = flagn(jl,2,js)*sttac(jl,2,js)
          sum_bb = sum_bb + weight(js)*(b_real*b_real + b_imag*b_imag)
       END DO
       DO jk=1,ndtem
          DO js=2,nsp
             sum_ab = 0.0
             sum_aa = 0.0
             a_real = pdtem(jl,1,js,jk)
             a_imag = pdtem(jl,2,js,jk)
             sum_aa = sum_aa + weight(js)*(a_real*a_real + a_imag*a_imag)
             b_real = flagn(jl,1,js)*sttac(jl,1,js)
             b_imag = flagn(jl,2,js)*sttac(jl,2,js)
             sum_ab = sum_ab + weight(js)*(a_real*b_real + a_imag*b_imag)
          END DO
          IF (sum_aa > 0.0 .AND. sum_bb > 0.0) THEN
             cc_tem(jk) = sum_ab/SQRT(sum_aa*sum_bb)
          ELSE
             cc_tem(jk) = 0.0
          END IF
       END DO
       WRITE(ndunit(14),'(a,i3,20(1x,f7.3))') 'TEM_L',jl,cc_tem(:)
    END DO

    ! pressure equation
    sum_bb = 0.0
    DO js=2,nsp
       b_real = flagn(nlevp1,1,js)*sttac(nlevp1,1,js)
       b_imag = flagn(nlevp1,2,js)*sttac(nlevp1,2,js)
       sum_bb = sum_bb + weight(js)*(b_real*b_real + b_imag*b_imag)
    END DO
    DO jk=1,ndprs
       DO js=2,nsp
          sum_ab = 0.0
          sum_aa = 0.0
          a_real = pdtem(nlevp1,1,js,jk)
          a_imag = pdtem(nlevp1,2,js,jk)
          sum_aa = sum_aa + weight(js)*(a_real*a_real + a_imag*a_imag)
          b_real = flagn(nlevp1,1,js)*sttac(nlevp1,1,js)
          b_imag = flagn(nlevp1,2,js)*sttac(nlevp1,2,js)
          sum_ab = sum_ab + weight(js)*(a_real*b_real + a_imag*b_imag)
       END DO
       IF (sum_aa > 0.0 .AND. sum_bb > 0.0) THEN
          cc_prs(jk) = sum_ab/SQRT(sum_aa*sum_bb)
       ELSE
          cc_prs(jk) = 0.0
       END IF
    END DO
    WRITE(ndunit(14),'(a,i3,20(1x,f7.3))') 'PRS_L',0,cc_prs(:)

  END SUBROUTINE Nudg_Correl

  SUBROUTINE Nudge_ResidueStore

    ! store resiude for later use
    IF (lrescor_b) THEN
       sdres_a(:,:,:) = sdres_b(:,:,:)
       svres_a(:,:,:) = svres_b(:,:,:)
       stres_a(:,:,:) = stres_b(:,:,:)
       lrescor_a = .TRUE.
    END IF
    sdres_b(:,:,:) = sdten(:,:,:)
    svres_b(:,:,:) = svten(:,:,:)
    stres_b(:,:,:) = stten(:,:,:)
    lrescor_b = .TRUE.

  END SUBROUTINE Nudge_ResidueStore

  SUBROUTINE Nudg_Update_Alpha
    ! calculates b_pat_xxx = a_pat_xxx + NORM(model,obs)
    INTEGER :: i
    REAL    :: aa(2,nsp), bb(2,nsp) 
    REAL    :: nnab, nnbb

    b_pat_vor(:,:) = 0.0
    IF (linp_vor) THEN
       DO i=ilev_v_min,ilev_v_max
          aa(:,:) = svo   (i,:,:)
          bb(:,:) = svobs1(i,:,:)
          CALL Nudg_Norm(aa,bb,nnp1,nsp,nnab)
          nnbb = a_nrm_vor(i,2)
          b_pat_vor(i,1) = a_pat_vor(i,2) - nnab/nnbb
          bb(:,:) = svobs2(i,:,:)
          CALL Nudg_Norm(aa,bb,nnp1,nsp,nnab)
          nnbb = a_nrm_vor(i,3)
          b_pat_vor(i,2) = a_pat_vor(i,3) - nnab/nnbb
       END DO
       IF (lnudgdbx) THEN
          WRITE(ndg_mess,'(a,40f12.4)') 'BETA(vor)1= ',b_pat_vor(:,1)
          CALL message('Nudg_Update_Alpha',ndg_mess)
          WRITE(ndg_mess,'(a,40f12.4)') 'BETA(vor)2= ',b_pat_vor(:,2)
          CALL message('Nudg_Update_Alpha',ndg_mess)
       END IF
    END IF

    b_pat_div(:,:) = 0.0
    IF (linp_div) THEN
       DO i=ilev_d_min,ilev_d_max
          aa(:,:) = sd    (i,:,:)
          bb(:,:) = sdobs1(i,:,:)
          CALL Nudg_Norm(aa,bb,nnp1,nsp,nnab)
          nnbb = a_nrm_div(i,2)
          b_pat_div(i,1) = a_pat_div(i,2) - nnab/nnbb
          bb(:,:) = sdobs2(i,:,:)
          CALL Nudg_Norm(aa,bb,nnp1,nsp,nnab)
          nnbb = a_nrm_div(i,3)
          b_pat_div(i,2) = a_pat_div(i,3) - nnab/nnbb
       END DO
       IF (lnudgdbx) THEN
          WRITE(ndg_mess,'(a,40f12.4)') 'BETA(div)1= ',b_pat_div(:,1)
          CALL message('Nudg_Update_Alpha',ndg_mess)
          WRITE(ndg_mess,'(a,40f12.4)') 'BETA(div)2= ',b_pat_div(:,2)
          CALL message('Nudg_Update_Alpha',ndg_mess)
       END IF
    END IF

    b_pat_tem(:,:) = 0.0
    IF (linp_tem) THEN
       DO i=ilev_t_min,ilev_t_max
          aa(:,:) = stp   (i,:,:)
          bb(:,:) = stobs1(i,:,:)
          CALL Nudg_Norm(aa,bb,nnp1,nsp,nnab)
          nnbb = a_nrm_tem(i,2)
          b_pat_tem(i,1) = a_pat_tem(i,2) - nnab/nnbb
          bb(:,:) = stobs2(i,:,:)
          CALL Nudg_Norm(aa,bb,nnp1,nsp,nnab)
          nnbb = a_nrm_tem(i,3)
          b_pat_tem(i,2) = a_pat_tem(i,3) - nnab/nnbb
       END DO
       IF (lnudgdbx) THEN
          WRITE(ndg_mess,'(a,40f12.4)') 'BETA(tem)1= ',b_pat_tem(:,1)
          CALL message('Nudg_Update_Alpha',ndg_mess)
          WRITE(ndg_mess,'(a,40f12.4)') 'BETA(tem)2= ',b_pat_tem(:,2)
          CALL message('Nudg_Update_Alpha',ndg_mess)
       END IF
    END IF

    b_pat_lnp(:) = 0.0
    IF (linp_lnp) THEN
       aa(:,:) = stp   (nlevp1,:,:)
       bb(:,:) = stobs1(nlevp1,:,:)
       CALL Nudg_Norm(aa,bb,nnp1,nsp,nnab)
       nnbb = a_nrm_lnp(2)
       b_pat_lnp(1) = a_pat_lnp(2) - nnab/nnbb
       bb(:,:) = stobs2(nlevp1,:,:)
       CALL Nudg_Norm(aa,bb,nnp1,nsp,nnab)
       nnbb = a_nrm_lnp(3)
       b_pat_lnp(2) = a_pat_lnp(3) - nnab/nnbb
       IF (lnudgdbx) THEN
          WRITE(ndg_mess,'(a,40f12.4)') 'BETA(lnps)1,2= ',b_pat_lnp(:)
          CALL message('Nudg_Update_Alpha',ndg_mess)
       END IF
    END IF

  END SUBROUTINE Nudg_Update_Alpha

  SUBROUTINE Nudg_Init_Alpha
    ! calculates b_pat_xxx = a_pat_xxx + NORM(model,obs)
    INTEGER :: i
    REAL    :: aa(2,nsp), bb(2,nsp) 
    REAL    :: nnab, nnbb

    ! block 0 contains climatology
    ! block 3 contains pattern

    IF (linp_vor) THEN
       DO i=ilev_v_min,ilev_v_max
          aa(:,:) = svobs3(i,:,:)
          bb(:,:) = svobs3(i,:,:)
          CALL Nudg_Norm(aa,bb,nnp1,nsp,nnbb)
          a_nrm_vor(i,4) = nnbb
          aa(:,:) = svobs0(i,:,:)
          bb(:,:) = svobs3(i,:,:)
          CALL Nudg_Norm(aa,bb,nnp1,nsp,nnab)
          a_pat_vor(i,4) = a_pat_vor(i,4) + nnab/nnbb
       END DO
    END IF

    IF (linp_div) THEN
       DO i=ilev_d_min,ilev_d_max
          aa(:,:) = sdobs3(i,:,:)
          bb(:,:) = sdobs3(i,:,:)
          CALL Nudg_Norm(aa,bb,nnp1,nsp,nnbb)
          a_nrm_div(i,4) = nnbb
          aa(:,:) = sdobs0(i,:,:)
          bb(:,:) = sdobs3(i,:,:)
          CALL Nudg_Norm(aa,bb,nnp1,nsp,nnab)
          a_pat_div(i,4) = a_pat_div(i,4) + nnab/nnbb
       END DO
    END IF

    IF (linp_tem) THEN
       DO i=ilev_t_min,ilev_t_max
          aa(:,:) = stobs3(i,:,:)
          bb(:,:) = stobs3(i,:,:)
          CALL Nudg_Norm(aa,bb,nnp1,nsp,nnbb)
          a_nrm_tem(i,4) = nnbb
          aa(:,:) = stobs0(i,:,:)
          bb(:,:) = stobs3(i,:,:)
          CALL Nudg_Norm(aa,bb,nnp1,nsp,nnab)
          a_pat_tem(i,4) = a_pat_tem(i,4) + nnab/nnbb
       END DO
    END IF

    IF (linp_lnp) THEN
       aa(:,:) = stobs3(nlevp1,:,:)
       bb(:,:) = stobs3(nlevp1,:,:)
       CALL Nudg_Norm(aa,bb,nnp1,nsp,nnbb)
       aa(:,:) = stobs0(nlevp1,:,:)
       bb(:,:) = stobs3(nlevp1,:,:)
       CALL Nudg_Norm(aa,bb,nnp1,nsp,nnab)
       a_pat_lnp(4) = a_pat_lnp(4) + nnab/nnbb
       a_nrm_lnp(4) = nnbb
    END IF

  END SUBROUTINE Nudg_Init_Alpha


!#ifdef LINUX

  SUBROUTINE r_swap32(rfield,idx)
    REAL :: rfield(:)
    INTEGER :: idx
    CALL swap32_main(rfield=rfield,idx=idx)
  END SUBROUTINE r_swap32

  SUBROUTINE i_swap32(ifield,idx)
    INTEGER :: ifield(:)
    INTEGER :: idx
    CALL swap32_main(ifield=ifield,idx=idx)
  END SUBROUTINE i_swap32

  SUBROUTINE c_swap32(cfield,idx)
    CHARACTER(len=8) :: cfield(:)
    INTEGER :: idx
    CALL swap32_main(cfield=cfield,idx=idx)
  END SUBROUTINE c_swap32

  SUBROUTINE swap32_main(rfield,ifield,cfield,idx)
    REAL, OPTIONAL         :: rfield(:)
    INTEGER, OPTIONAL      :: ifield(:)
    CHARACTER(len=8), OPTIONAL :: cfield(:)
    INTEGER :: idx
    INTEGER :: i, j
    CHARACTER(len=8),ALLOCATABLE :: ctr(:)
    CHARACTER(len=1)             :: tmp(8)

    ALLOCATE(ctr(idx))

    IF (PRESENT(rfield)) THEN
       ctr(1:idx) = TRANSFER(rfield(1:idx),ctr)

    ELSE IF(PRESENT(ifield)) THEN
       ctr(1:idx) = TRANSFER(ifield(1:idx),ctr)

    ELSE IF(PRESENT(cfield)) THEN
       ctr(1:idx) = cfield(1:idx)

    END IF

    ! switch bytes
    DO i=1,idx
       DO j=1,8
          tmp(j) = ctr(i)(j:j)
       END DO
       DO j=1,8
          ctr(i)(j:j) = tmp(9-j)
       END DO
    END DO

    IF (PRESENT(rfield)) THEN
       rfield(1:idx) = TRANSFER(ctr(1:idx),rfield)

    ELSE IF(PRESENT(ifield)) THEN
       ifield(1:idx) = TRANSFER(ctr(1:idx),ifield)

    ELSE IF(PRESENT(cfield)) THEN
       cfield(1:idx) = ctr(1:idx)

    END IF

    DEALLOCATE(ctr)

  END SUBROUTINE swap32_main

!#endif

  !======================================================================

  SUBROUTINE cpbread(unit,cfield,nbytes,ierr)
    USE mo_kind, ONLY: cp

    INTEGER(cp)  :: unit
    CHARACTER(len=8) :: cfield(:)
    INTEGER      :: nbytes
    INTEGER      :: ierr

    REAL, ALLOCATABLE :: field(:)

    EXTERNAL :: pbread

    INTEGER :: no

    no = INT(nbytes/8)
    ALLOCATE(field(no))

    CALL pbread(unit,field(1),nbytes,ierr)

    IF (ierr >= 0) THEN
       cfield = TRANSFER(field(1:no),cfield)
    END IF

    IF (ndgswap) CALL swap32(cfield,no)

    DEALLOCATE(field)

  END SUBROUTINE cpbread

  !======================================================================

END MODULE mo_nudging
