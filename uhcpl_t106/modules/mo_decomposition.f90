MODULE mo_decomposition
  !
  !+ $Id: mo_decomposition.f90,v 1.33 2000/05/18 07:12:12 m214030 Exp $
  !
  USE mo_exception, ONLY : finish

  IMPLICIT NONE

  PRIVATE
  !
  ! Data type declaration
  !
  PUBLIC :: pe_decomposed        ! data type to hold decomposition for 
  ! a single PE
  !
  ! Module variables
  !
  PUBLIC :: global_decomposition ! decomposition table for all PEs
  PUBLIC :: local_decomposition  ! decomposition info for this PE
  PUBLIC :: debug_parallel       ! Debug flag: -1= no debugging, 0,1=debugging
  PUBLIC :: debug_seriell        ! .true. to use old scheme to cycle longitudes
  PUBLIC :: any_col_1d           ! .true. if column model runs on any PE
  ! compatible with seriell model version. 
  ! works only for nprocb==1
  !
  ! Module procedures
  !
  PUBLIC :: decompose            ! derive decomposition table
  PUBLIC :: print_decomposition  ! print decomposition table

  ! Data type for local information of decomposition per PE 

  TYPE pe_decomposed

     ! Information regarding the whole model domain and discretization

     INTEGER          :: nlon      ! number of longitudes
     INTEGER          :: nlat      ! number of latitudes
     INTEGER          :: nlev      ! number of levels
     INTEGER          :: nm        ! max. wavenumber used(triangular truncation)
     INTEGER ,POINTER :: nnp(:)    ! number of points on each m-column
     INTEGER ,POINTER :: nmp(:)    ! displacement of the first point of
     ! m-columns with respect to the first point 
     ! of the first m-column

     ! General information on the decomposition

     INTEGER          :: d_nprocs  ! # of PEs for debugging/non-debugging domain
     INTEGER          :: spe       ! index # of first PE of domain
     INTEGER          :: epe       ! index # of last PE of domain
     INTEGER          :: nprocb    !#of PEs for dimension that counts longitudes
     INTEGER          :: nproca    !#of PEs for dimension that counts latitudes
     INTEGER ,POINTER :: mapmesh(:,:) ! indirection array mapping from a
     ! logical 2-d mesh to the processor index
     ! numbers
     ! local information

     INTEGER          :: pe        ! PE id 
     INTEGER          :: set_b     ! PE id in direction of longitudes
     INTEGER          :: set_a     ! PE id in direction of latitudes 
     LOGICAL          :: col_1d    ! 1d column model(s) on this pe

     ! Grid space decomposition 

     INTEGER          :: nglat     ! number of latitudes  on PE
     INTEGER          :: nglon     ! number of longitudes on PE
     INTEGER          :: nglpx     ! number of longitudes allocated
     INTEGER          :: nglh(2)   ! number of latitudes on each hemisphere
     INTEGER          :: glats(2)  ! start values of latitudes
     INTEGER          :: glate(2)  ! end values of latitudes
     INTEGER          :: glons(2)  ! start values of longitudes
     INTEGER          :: glone(2)  ! end values of longitudes
     INTEGER ,POINTER :: glat(:)   ! global latitude index
     INTEGER ,POINTER :: glon(:)   ! offset to global longitude

     ! Fourier space decomposition

     LOGICAL          :: lfused    ! true if this PE used in Fourier space
     INTEGER          :: nflat     ! number of latitudes on PE
     INTEGER          :: nflev     ! number of levels on PE
     INTEGER          :: nflevp1   ! number of levels+1 on PE
     INTEGER          :: flats(2)  ! start values of latitudes (on row)
     INTEGER          :: flate(2)  ! end values of latitudes (on row)
     INTEGER          :: flevs     ! start values of levels (on column)
     INTEGER          :: fleve     ! end values of levels (on column)

     ! Legendre space decomposition

     ! Row of PEs with same set_a
     INTEGER          :: nlm       ! number of local wave numbers m handled
     INTEGER ,POINTER :: lm(:)     ! actual local wave numbers m handled
     INTEGER          :: lnsp      ! number of complex spectral coefficients  
     INTEGER ,POINTER :: nlmp(:)   ! displacement of the first point of columns
     INTEGER ,POINTER :: nlnp(:)   ! number of points on each column
     INTEGER          :: nlnm0     ! number of coeff. with m=0 on this pe
     INTEGER ,POINTER :: intr(:)   ! index array used by transpose routine

     ! Column of PEs with same set_b
     INTEGER          :: nllev     ! number of levels
     INTEGER          :: nllevp1   ! number of levels+1
     INTEGER          :: llevs     ! start values of levels
     INTEGER          :: lleve     ! end values of levels

     ! Spectral space decomposition

     ! local PE
     INTEGER          :: snsp      ! number of spectral coefficients
     INTEGER          :: snsp2     ! 2*number of spectral coefficients
     INTEGER          :: ssps      ! first spectral coefficient
     INTEGER          :: sspe      ! last  spectral coefficient

     LOGICAL          :: lfirstc   ! true, if first global coeff (m=0,n=0) on
     ! this PE (for nudging)
     INTEGER          :: ifirstc   ! location of first global coeff on this PE
     INTEGER ,POINTER :: np1(:)    ! value of (n+1) for all coeffs of this PE 
     INTEGER ,POINTER :: mymsp(:)  ! value of m for all coeffs of this PE
     INTEGER          :: nns       ! number of different n-values for this PE
     INTEGER ,POINTER :: nindex(:) ! the nns elements contain the
     ! values of (n+1)

     INTEGER          :: nsm       ! number of wavenumbers per PE
     INTEGER ,POINTER :: sm (:)    ! actual local wave numbers handled
     INTEGER ,POINTER :: snnp(:)   ! number of n coeff. per wave number m
     INTEGER ,POINTER :: snn0(:)   ! first coeff. n for a given m
     INTEGER          :: nsnm0     ! number of coeffs with m=0 on this pe

  END TYPE pe_decomposed

  ! Module variables

  TYPE (pe_decomposed), POINTER, SAVE :: global_decomposition(:)
  TYPE (pe_decomposed), SAVE          :: local_decomposition

  INTEGER                             :: debug_parallel = -1
  ! -1 no debugging
  ! 0 gather from PE0
  ! 1 gather from PE>0
  LOGICAL                             :: debug_seriell = .FALSE.
  ! .true. to use old scheme to cycle longitudes
  ! compatible with seriell model version.
  ! works only for nprocb==1
  LOGICAL                             :: any_col_1d = .FALSE.
  ! a column model is running on any of the PE's

CONTAINS

  ! Module routines

  SUBROUTINE decompose (global_dc, nproca, nprocb, nlat, nlon, nlev, &
       &                       nm, nn, nk, norot, debug, lfull_m, &
       &                       lats_1d, lons_1d)
  !
  ! set decomposition table 
  !
  ! module used
  !
  USE mo_doctor,    ONLY: nerr
  USE mo_mpi,       ONLY: p_nprocs, p_set_communicator
  !
  ! arguments
  !
  TYPE (pe_decomposed),INTENT(out) :: global_dc(0:)   ! decomposition table
  INTEGER             ,INTENT(in)  :: nproca, nprocb  ! no pe's in set A,B
  INTEGER             ,INTENT(in)  :: nlat, nlon, nlev! grid space size
  INTEGER             ,INTENT(in)  :: nk, nm, nn      ! truncation
  LOGICAL ,OPTIONAL   ,INTENT(in)  :: norot           ! T:no lons rotation 
  INTEGER ,OPTIONAL   ,INTENT(in)  :: debug           ! run full model on PE0
  LOGICAL ,OPTIONAL   ,INTENT(in)  :: lfull_m         ! T: full columns
  INTEGER ,OPTIONAL   ,INTENT(in)  :: lats_1d         ! lats (column model)
  INTEGER ,OPTIONAL   ,INTENT(in)  :: lons_1d         ! lons (column model)
    !
    ! local variables
    !
    INTEGER :: pe, i
    INTEGER :: nprocs
    LOGICAL :: nor
    LOGICAL :: lfullm
    !
    ! check consistency of arguments
    !
    IF (nlat/2 < nproca) THEN
       CALL finish ('decompose', &
       &            'Too many PEs selected for nproca - must be <= nlat/2.')
    END IF

    IF (nm+1 < nproca) THEN
       CALL finish ('decompose', &
       &            'Too many PEs selected for nproca - must be <= nm+1.')
    END IF

    IF (nk /= nm .OR. nn /= nm) THEN
       CALL finish ('decompose', &
       &            'Only triangular truncations supported in parallel mode.')
    END IF
    !
    ! set local variables
    !
    nor    = .FALSE.; IF (PRESENT(norot )) nor = norot
    nprocs = nproca*nprocb
    IF (PRESENT(debug)) debug_parallel = debug
    lfullm = .FALSE.
    IF (PRESENT(lfull_m)) lfullm = lfull_m
    !
    ! set module variables
    !
    any_col_1d = PRESENT(lats_1d).AND.PRESENT(lons_1d)

    pe = 0
    IF (debug_parallel >= 0) THEN
       !
       ! set entries for full (debugging) model
       !
       ALLOCATE (global_dc(pe)%mapmesh(1:1,1:1))
       global_dc(pe)% d_nprocs = 1 ! # of PEs for debug domain
       global_dc(pe)% spe      = 1 ! index number of first PE for debug domain
       global_dc(pe)% epe      = 1 ! index number of last PE for debug domain
       !
       ! set entries for regular (partitioned) model
       !
       DO i=pe+1,UBOUND(global_dc,1)
          ALLOCATE (global_dc(i)%mapmesh(1:nprocb,1:nproca))
       END DO
       global_dc(pe+1:)% d_nprocs = p_nprocs - 1 ! normal domain
       global_dc(pe+1:)% spe      = 2            ! normal domain
       global_dc(pe+1:)% epe      = p_nprocs     ! normal domain
    ELSE
       !
       ! set entries for regular (partitioned) model
       !
       DO i=pe,UBOUND(global_dc,1)
          ALLOCATE (global_dc(i)%mapmesh(1:nprocb,1:nproca))
       END DO
       global_dc(pe:)% d_nprocs = p_nprocs
       global_dc(pe:)% spe      = 1
       global_dc(pe:)% epe      = p_nprocs
    END IF

    IF (debug_parallel >= 0) THEN
       !
       ! debug: PE 0 takes whole domain
       !
       CALL set_decomposition (global_dc(pe:pe), pe, 1, 1, .TRUE., lfullm)
       ! from now on the coordinates of the debug PE in the logical
       ! mesh must be different from all other PEs' coordinates in order
       ! to avoid communication in the transposition routines
       pe = pe + 1
       nprocs = nprocs + 1
    END IF
    !
    ! some more consistency checks
    !
    IF (nprocs /= SIZE(global_dc)) THEN
       WRITE(nerr,*) 'nprocs,size(global_dc):', nprocs, SIZE(global_dc)
       CALL finish ('decompose', 'wrong size of global_dc.')
    END IF

    IF (nprocs /= p_nprocs) THEN
       CALL finish('decompose', &
            &            'Inconsistent total number of used PEs.')
    END IF
    !
    ! set entries for regular (partitioned) model
    !
    CALL set_decomposition (global_dc(pe:), pe, nproca, nprocb, nor, lfullm, &
                            lats_1d=lats_1d, lons_1d=lons_1d)
    CALL p_set_communicator (nproca, nprocb, global_dc(pe)%mapmesh, & 
         debug_parallel)
  CONTAINS

    SUBROUTINE set_decomposition (dc, pe, nproca, nprocb, noro, lfullm, &
                                  lats_1d, lons_1d)
    !
    ! set decomposition table for one model instance
    !
    TYPE (pe_decomposed) :: dc(0:)          ! decomposition table
    INTEGER              :: pe              ! pe of dc(0)
    INTEGER              :: nproca, nprocb  ! no pe's in columns and rows
    LOGICAL              :: noro            ! T: no lons rotation
    LOGICAL              :: lfullm          ! T: full columns
    INTEGER ,OPTIONAL    :: lats_1d         ! lats (column model)
    INTEGER ,OPTIONAL    :: lons_1d         ! lons (column model)

      INTEGER :: mepmash(nprocb,nproca)
      INTEGER :: i, p

      p = pe
      CALL decompose_global (dc, nlon, nlat, nlev, nm, nproca, nprocb)
      DO i = 0, UBOUND(dc,1)
         dc(i)%pe    = p                 ! local PE id 
         CALL mesh_map_init(-1, nprocb, nproca, pe, mepmash)
         dc(i)%mapmesh(:,:) = mepmash(:,:)

         CALL mesh_index(dc(i)%pe, nprocb, nproca, dc(i)%mapmesh, &
              dc(i)%set_b, dc(i)%set_a)

         CALL decompose_grid   (dc(i), noro, lats_1d=lats_1d, lons_1d=lons_1d)
         CALL decompose_level  (dc(i)) 
         CALL decompose_wavenumbers_row (dc(i))
         CALL decompose_specpoints_pe (dc(i), lfullm)

         p = p+1

      END DO

    END SUBROUTINE set_decomposition

  END SUBROUTINE decompose

  SUBROUTINE decompose_global (global_dc, nlon, nlat, nlev, nm, &
                               nproca, nprocb)
  !--------------------------------------------------------
  ! set information on global domain in decomposition table
  !--------------------------------------------------------
  TYPE (pe_decomposed) ,INTENT(inout) :: global_dc(:) ! decomposition table
  INTEGER              ,INTENT(in)    :: nlon         ! # of longitudes
  INTEGER              ,INTENT(in)    :: nlat         ! # of latitudes
  INTEGER              ,INTENT(in)    :: nlev         ! # of levels
  INTEGER              ,INTENT(in)    :: nm           ! truncation
  INTEGER              ,INTENT(in)    :: nproca       ! # of PE's in N-S dir.
  INTEGER              ,INTENT(in)    :: nprocb       ! # of PE's in E-W dir.
    !
    ! local scalars
    !
    INTEGER :: m, nn, nk, i
    !
    ! executable statements
    !
    global_dc% nlon   = nlon
    global_dc% nlat   = nlat
    global_dc% nlev   = nlev
    global_dc% nm     = nm
    global_dc% nproca = nproca
    global_dc% nprocb = nprocb
    nn = nm; nk = nm
    DO i=1,SIZE(global_dc,1)
       ALLOCATE (global_dc(i)% nnp(nm+1))
       ALLOCATE (global_dc(i)% nmp(nm+2))
       globaL_dc(i)%nnp=-999
       global_dc(i)%nmp=-999
    END DO
    DO m=0,nm
       global_dc(1)% nmp(1) = 0
       global_dc(1)% nnp(m+1) = MIN (nk-m,nn) + 1
       global_dc(1)% nmp(m+2) = global_dc(1)% nmp(m+1) + global_dc(1)% nnp(m+1)
    END DO
    DO i=2,SIZE(global_dc,1)
       global_dc(i)% nnp = global_dc(1)% nnp
       global_dc(i)% nmp = global_dc(1)% nmp
    END DO

  END SUBROUTINE decompose_global

  SUBROUTINE decompose_grid (pe_dc, norot, lats_1d, lons_1d) 
  !
  ! sets information on local gridpoint space in decomposition table entry
  !
  TYPE (pe_decomposed) ,INTENT(inout) :: pe_dc ! decomposition table entry
  LOGICAL              ,INTENT(in)    :: norot   ! rotate domain in south. hem.
  INTEGER  ,OPTIONAL   ,INTENT(in)    :: lats_1d ! latitude for column model
  INTEGER  ,OPTIONAL   ,INTENT(in)    :: lons_1d ! longitude for column model
    !
    ! local variables
    !
    INTEGER :: ngl, i, inp, inprest
    INTEGER :: nptrlat(pe_dc% nproca+1), nptrlon(pe_dc% nprocb+1)
    INTEGER :: set_a, set_b, nlon, nlat, nproca, nprocb
    !
    ! executable statements
    !
    IF(PRESENT(lats_1d).AND.PRESENT(lons_1d)) THEN
      !
      ! column model settings
      !
      pe_dc% col_1d = .TRUE.
      !
      ! latitudes
      !
      pe_dc% nglat    = 1
      pe_dc% nglh     = (/1,0/)
      pe_dc% glats(1) = lats_1d
      pe_dc% glate(1) = lats_1d
      pe_dc% glats(2) = 1
      pe_dc% glate(2) = 0
      ALLOCATE (pe_dc% glat(1))
      pe_dc% glat     = lats_1d
      !
      ! longitudes
      !
      pe_dc% nglon    = 1
      pe_dc% glons(1) = lons_1d
      pe_dc% glone(1) = lons_1d
      pe_dc% glons(2) = 1
      pe_dc% glone(2) = 0
      ALLOCATE (pe_dc% glon(1))
      pe_dc% glon     = lons_1d - 1
    ELSE
      !
      ! full model settings
      !
      pe_dc% col_1d = .FALSE.
      !
      ! local copies of decomposition table entries
      !
      set_a  = pe_dc% set_a
      set_b  = pe_dc% set_b
      nlon   = pe_dc% nlon
      nlat   = pe_dc% nlat
      nproca = pe_dc% nproca
      nprocb = pe_dc% nprocb
      !
      ! first distribute latitudes
      !
      ngl = nlat/2

      nptrlat(:) = -999 

      inp = ngl/nproca
      inprest = ngl-inp*nproca
      nptrlat(1) = 1
      DO i = 1, nproca
         IF (i <= inprest) THEN
            nptrlat(i+1) = nptrlat(i)+inp+1
         ELSE
            nptrlat(i+1) = nptrlat(i)+inp   
         END IF
      END DO
      !
      ! now distribute longitudes
      !
      nptrlon(:) = -999 

      inp = nlon/nprocb
      inprest = nlon-inp*nprocb
      nptrlon(1) = 1
      DO i = 1, nprocb
         IF (i <= inprest) THEN
            nptrlon(i+1) = nptrlon(i)+inp+1
         ELSE
            nptrlon(i+1) = nptrlon(i)+inp   
         END IF
      END DO

      ! define parts per pe
      !
      ! latitudes
      !
      pe_dc% nglat    =  2*(nptrlat(set_a+1)-nptrlat(set_a))
      pe_dc% nglh     =  pe_dc% nglat/2

      pe_dc% glats(1) = nptrlat(set_a)
      pe_dc% glate(1) = nptrlat(set_a+1)-1

      pe_dc% glats(2) = nlat-nptrlat(set_a+1)+2 
      pe_dc% glate(2) = nlat-nptrlat(set_a)+1

      ALLOCATE (pe_dc% glat( pe_dc% nglat))
      pe_dc% glat(1:pe_dc% nglat/2) = (/(i,i=pe_dc% glats(1),pe_dc% glate(1))/)
      pe_dc% glat(pe_dc% nglat/2+1:)= (/(i,i=pe_dc% glats(2),pe_dc% glate(2))/)
      !
      ! longitudes
      !
      pe_dc% nglon    = nptrlon(set_b+1)-nptrlon(set_b)
      pe_dc% glons(1) = nptrlon(set_b)
      pe_dc% glone(1) = nptrlon(set_b+1)-1
      !
      ! rotate longitudes in southern area
      !
      IF (norot) THEN
         pe_dc% glons(2) = pe_dc% glons(1)
         pe_dc% glone(2) = pe_dc% glone(1)
      ELSE
         pe_dc% glons(2) = MOD(nptrlon(set_b)-1+nlon/2, nlon)+1
         pe_dc% glone(2) = MOD(nptrlon(set_b+1)-2+nlon/2, nlon)+1
      END IF

      ALLOCATE (pe_dc% glon( pe_dc% nglat))
      pe_dc% glon(1:pe_dc% nglat/2)  = pe_dc% glons(1)-1
      pe_dc% glon(pe_dc% nglat/2+1:) = pe_dc% glons(2)-1
    ENDIF
    !
    ! number of longitudes to allocate
    !
    IF (norot .AND. nproca*nprocb==1) THEN
       pe_dc% nglpx = pe_dc% nglon + 2
    ELSE
       pe_dc% nglpx = pe_dc% nglon
    END IF
    if (pe_dc% col_1d) pe_dc% nglpx = pe_dc% nglon

  END SUBROUTINE decompose_grid

  SUBROUTINE decompose_level (pe_dc)
  !
  ! determine number of local levels for fourier and legendre calculations
  ! this is based on the supplied nlev and nprocb
  !
  TYPE (pe_decomposed), INTENT(inout) :: pe_dc

    INTEGER :: set_b, nlev, nprocb
    INTEGER :: inp, inprest, jb

    INTEGER :: ll(pe_dc% nprocb+1), nptrll(pe_dc% nprocb+1)
    !
    ! copy table entries to local variables
    !
    set_b  = pe_dc% set_b
    nlev   = pe_dc% nlev
    nprocb = pe_dc% nprocb
    IF (pe_dc% col_1d) THEN
      !
      ! settings for column model
      !
      pe_dc% nflat   = 0
      pe_dc% flats   = 1
      pe_dc% flate   = 0
      pe_dc% nflevp1 = 0
      pe_dc% flevs   = 1
      pe_dc% fleve   = 0
      pe_dc% lfused  = .FALSE.
      pe_dc% nflev   = 0
    ELSE
      !
      ! settings for full model
      !
      ! latitudes are the same as in grid space
      !
      pe_dc% nflat = pe_dc% nglat
      pe_dc% flats = pe_dc% glats
      pe_dc% flate = pe_dc% glate
      !
      ! distribute levels
      !
      inp = (nlev+1)/nprocb
      inprest = (nlev+1)-inp*nprocb
      !
      ! make sure highest level is on a PE which has one of the subsets with an
      ! extra level => improves load-balance
      !
      nptrll(nprocb+1)=nlev+1+1
      DO jb = nprocb,1,-1
         IF ((nprocb - jb + 1) <= inprest) THEN 
            ll(jb) = inp+1
         ELSE
            ll(jb) = inp
         END IF
         nptrll(jb) = nptrll(jb+1)-ll(jb)
      END DO

      pe_dc% nflevp1 = ll(set_b)
      pe_dc% flevs   = nptrll(set_b)
      pe_dc% fleve   = nptrll(set_b+1)-1
      pe_dc% lfused  = pe_dc%nflevp1 > 0

      IF ( pe_dc%fleve > nlev ) THEN
         pe_dc%nflev = pe_dc%nflevp1 - 1
      ELSE
         pe_dc%nflev = pe_dc%nflevp1
      END IF
    ENDIF
  END SUBROUTINE decompose_level

  SUBROUTINE decompose_wavenumbers_row (pe_dc)
  TYPE (pe_decomposed), INTENT(inout) :: pe_dc
  !
  ! decompose wavenumbers along latitudinal direction (nproca)
  !
    INTEGER :: jm, ik, il, ind

    INTEGER :: set_a, nm, nproca

    INTEGER :: nprocm(0:pe_dc% nm)   ! 'set_a' for a certain spectral wave
    INTEGER :: nspec (pe_dc% nproca) ! complex spectral coeff. per row (set_a)
    INTEGER :: numpp (pe_dc% nproca) ! spectral waves per processor row (set_a)
    INTEGER :: myms  (pe_dc% nm+1)   ! actual wave numbers handled
    !
    ! copy decomposition table entries to local variables
    !
    set_a  = pe_dc% set_a
    nm     = pe_dc% nm
    nproca = pe_dc% nproca
    !
    ! levels same as in Fourier space
    !
    pe_dc% nllev   = pe_dc% nflev
    pe_dc% nllevp1 = pe_dc% nflevp1
    pe_dc% llevs   = pe_dc% flevs
    pe_dc% lleve   = pe_dc% fleve
    !
    ! distribute spectral waves
    !
    nspec(:) = 0
    numpp(:) = 0
    myms(:)  = -1
    il       = 1

    IF (pe_dc% col_1d) THEN
      !
      ! column model settings
      !
      nm = -1
    ELSE
      !
      ! full model settings
      !
      ind = 1
      ik  = 0
      DO jm = 0, nm
         ik = ik + ind
         IF (ik > nproca) THEN
            ik = nproca
            ind = -1
         ELSE IF (ik < 1) THEN
            ik = 1
            ind = 1
         END IF
         nprocm(jm) = ik
         nspec(ik) = nspec(ik)+nm-jm+1
         numpp(ik) = numpp(ik)+1
         IF (ik == set_a) THEN
            myms(il) = jm
            il = il+1
         END IF
      END DO
    ENDIF

    ALLOCATE(pe_dc% lm   (numpp(set_a)  ))
    ALLOCATE(pe_dc% nlmp (numpp(set_a)+1))
    ALLOCATE(pe_dc% nlnp (numpp(set_a)  ))
    ALLOCATE(pe_dc% intr (numpp(set_a)*2))

    pe_dc% nlm     = numpp(set_a)
    pe_dc% lnsp    = nspec(set_a)
    pe_dc% lm      = myms (1:il-1)
    pe_dc% nlnp    = nm - pe_dc% lm + 1
    pe_dc% nlnm0   = 0; IF (myms (1)== 0) pe_dc% nlnm0 = pe_dc% nlnp(1)
    pe_dc% nlmp(1) = 0
    DO jm = 1, pe_dc% nlm
       pe_dc% nlmp(  jm+1) = pe_dc% nlmp(jm) + pe_dc% nlnp(jm)
       pe_dc% intr(2*jm-1) = 2 * pe_dc% lm(jm) + 1
       pe_dc% intr(2*jm  ) = 2 * pe_dc% lm(jm) + 2
    END DO

  END SUBROUTINE decompose_wavenumbers_row

  SUBROUTINE decompose_specpoints_pe (pe_dc, lfullm)
  USE mo_exception
  LOGICAL ,INTENT(in) :: lfullm

    ! Decompose wavenumbers additionally along longitudinal direction (nprocb),
    ! thus decompose wavenumbers among individual PEs.
    ! Each PE receives full or partial m-columns, depending on strategy 
    ! chosen. The case with partial m-columns will generally be better load-
    ! balanced.


    TYPE (pe_decomposed), INTENT(inout) :: pe_dc

    INTEGER :: nspec, set_b, nump, myml(pe_dc%nlm)

    INTEGER :: insef, irestf, jb, jmloc, icolset, iave, im, inm, iii, jn, i
    INTEGER :: ispec, il, jm, imp, inp, is, ic, inns, nsm, ifirstc
    INTEGER :: nm, nprocb

    INTEGER :: nptrsv (pe_dc% nprocb+1) ! first spectral wave column (PE)
    INTEGER :: nptrsvf(pe_dc% nprocb+1) ! full spectral wave m-columns (PE)
    INTEGER :: nptrmf (pe_dc% nprocb+1) ! distribution of m-columns among PE
    ! columns (used for semi-impl. calculations in full m-columns case)
    INTEGER :: nspstaf(0:pe_dc% nm)     ! m-column starts here (used for 
    ! semi-impl. full m-columns case)

    INTEGER :: inumsvf(pe_dc% nprocb+1)

    INTEGER :: nns               ! number of different n-values for this PE
    INTEGER :: nindex(pe_dc%nm+1)! the first nns elements contain the values 
    ! of (n+1);
    ! for non triangular truncation: pe_dc%nkp1
    LOGICAL :: lnp1(pe_dc%nm+1)  ! if false: this value of (n+1) has not 
    ! occurred yet

    INTEGER :: np1(pe_dc%lnsp)   ! np1 holds the values of (n+1) of all
    ! coeffs on this PE
    INTEGER :: mymsp(pe_dc%lnsp) ! mymsp holds the values of m of all
    ! coeffs on this PE

    INTEGER :: myms(pe_dc%nlm)   ! myms holds the values of the wavenumbers
    ! on this PE 
    INTEGER :: myns(pe_dc%nlm)   ! myns holds the number of coeffs of
    ! m-columns (full or partial) on this PE
    INTEGER :: snn0(pe_dc%nlm)   ! snn0 holds the offset of n wavenumbers
    ! for each column (0 for full)

    LOGICAL :: ljm, lfirstc

    ! executable statements

    ! short names for processor row variables

    nspec  = pe_dc% lnsp   ! number of spectral coefficients in processor row
    nump   = pe_dc% nlm    ! number of wavenumbers in processor row
    myml   = pe_dc% lm     ! wave numbers handled in processor row
    nm     = pe_dc% nm     ! max. wavenumber used(triangular truncation)
    nprocb = pe_dc% nprocb ! number of PEs in set
    set_b  = pe_dc% set_b  ! index of PE in set

    ! Partitioning of spectral coefficients in semi-implicit calculations.
    ! Be careful : nspec varies between processor rows, so nptrsv() 
    ! differs on different processor rows.

    insef = nspec/nprocb
    irestf = nspec-insef*nprocb
    nptrsv(1) = 1
    DO jb = 2, nprocb+1
       IF(jb-1 <= irestf) THEN
          nptrsv(jb) = nptrsv(jb-1)+insef+1
       ELSE
          nptrsv(jb) = nptrsv(jb-1)+insef
       END IF
    END DO

    ! partitioning of spectral coefficients in semi-implicit calculations
    ! for the case where complete m-columns are required.

    ! original idea

    nptrmf(:) = 1
    inumsvf(:) = 0
    icolset = MIN(nprocb,nump)
    nptrmf(1) = 1
    nptrmf(icolset+1:nprocb+1) = nump+1
    ispec = nspec
    IF (nump>0) THEN
      iave = (ispec-1)/icolset+1
      DO jmloc = nump, 1, -1
         im = myml(jmloc)
         inm = nm-im+1
         IF (inumsvf(icolset) < iave) THEN
            inumsvf(icolset) = inumsvf(icolset)+inm
         ELSE
            nptrmf(icolset) = jmloc+1
            ispec = ispec-inumsvf(icolset)
            icolset = icolset-1
            IF (icolset == 0) THEN
               CALL finish ('decompose_wavenumbers_pe', &
                    &                'error in decomposition, icolset = 0!')
            END IF
            iave = (ispec-1)/icolset+1
            inumsvf(icolset) = inumsvf(icolset)+inm
         END IF
      END DO
    ENDIF
    nptrsvf(1) = 1
    DO jb = 2, nprocb+1
       nptrsvf(jb) = nptrsvf(jb-1)+inumsvf(jb-1)
    END DO

    nspstaf(:) = -999
    iii = 1
    !    DO jmloc = nptrmf(set_b), nptrmf(set_b+1)-1
    !      nspstaf(myml(jmloc)) = iii
    !      iii = iii+nm-myms(jmloc)+1
    !    END DO

    IF (lfullm) THEN
       pe_dc%ssps = nptrsvf(set_b)
       pe_dc%sspe = nptrsvf(set_b+1)-1
       pe_dc%snsp = nptrsvf(set_b+1)-nptrsvf(set_b)
       pe_dc%snsp2= 2*pe_dc%snsp
    ELSE
       pe_dc%ssps = nptrsv(set_b)
       pe_dc%sspe = nptrsv(set_b+1)-1
       pe_dc%snsp = nptrsv(set_b+1)-nptrsv(set_b)
       pe_dc%snsp2= 2*pe_dc%snsp
    END IF

    ! il counts spectral coeffs per PE
    ! nsm counts number of wavenumbers (full or partial) per PE

    il  = 0
    nsm = 0
    ljm = .FALSE.
    lnp1(:) = .FALSE.
    nindex(:) = -999
    inns = 0
    myms(:) = -999
    myns(:) = 0
    ifirstc = -999
    lfirstc = .FALSE.

    ! loop over all coeffs of a processor row and check whether they belong to
    ! this PE

    DO jm = 1,nump
       imp = pe_dc%nlmp(jm)
       inp = pe_dc%nlnp(jm)
       DO jn = 1,inp
          is = imp + jn
          ic = myml(jm) +jn

          IF ((is >= pe_dc%ssps) .AND. (is <= pe_dc%sspe)) THEN
             IF (.NOT.ljm) snn0 (nsm+1) = jn-1
             ljm = .TRUE.
             il  = il + 1

             np1(il) = ic
             mymsp(il) = myml(jm)

             myns(nsm+1) = myns(nsm+1) + 1

             IF (.NOT. lnp1(ic)) THEN
                inns = inns + 1
                nindex(inns) = ic
                lnp1(ic) = .TRUE.
             END IF

             ! first global coeff. on this PE? (for nudging)
             IF ((mymsp(il) == 0) .AND. (np1(il) == 1)) THEN
                lfirstc = .TRUE.
                ifirstc = il
             END IF

          END IF
       END DO
       IF (ljm) THEN
          nsm = nsm + 1
          myms(nsm) = myml(jm)
       END IF
       ljm = .FALSE.
    END DO

    nns = inns

    IF (il /= pe_dc%snsp) THEN
       CALL finish('decompose', &
            &            'Error in computing number of spectral coeffs')
    END IF

    ALLOCATE (pe_dc%np1(il))
    ALLOCATE (pe_dc%mymsp(il))
    pe_dc%np1 = np1(1:il)
    pe_dc%mymsp = mymsp(1:il)

    pe_dc%nns = nns
    ALLOCATE (pe_dc%nindex(pe_dc%nns))
    pe_dc%nindex(:) = nindex(1:nns)

    pe_dc%lfirstc = lfirstc
    pe_dc%ifirstc = ifirstc

    pe_dc%nsm = nsm
    ALLOCATE (pe_dc%sm (pe_dc%nsm))
    ALLOCATE (pe_dc%snnp (pe_dc%nsm))
    pe_dc%sm = myms(1:nsm)
    pe_dc%snnp = myns(1:nsm)

    ALLOCATE (pe_dc%snn0 (pe_dc%nsm))
    pe_dc%snn0 = snn0 (1:nsm)

    pe_dc%nsnm0 = 0
    DO i=1,nsm
       IF (pe_dc%sm(i) == 0) THEN
          pe_dc%nsnm0 = pe_dc%snnp(i)
          EXIT
       END IF
    END DO

  END SUBROUTINE decompose_specpoints_pe

  SUBROUTINE print_decomposition (dc)

    USE mo_doctor,    ONLY: nout
    USE mo_exception, ONLY: message

    TYPE (pe_decomposed), INTENT(in) :: dc

    WRITE (nout,'(78("_"))')
    IF (.NOT. ASSOCIATED(dc%lm)) THEN
       CALL message ('print_decomposition', &
            &            'decomposition not done, cannot print information ...')
    END IF

    WRITE (nout,'(a,i5)') ' PE    : ', dc%pe
    WRITE (nout,'(a,i5)') ' Processor row    (Set A) : ', dc%set_a
    WRITE (nout,'(a,i5)') ' Processor column (Set B) : ', dc%set_b
    WRITE (nout,'(a,l5)') ' Column model running     : ', dc%col_1d

    WRITE (nout,*)

    WRITE (nout,'(a)') ' mapmesh : '
    WRITE (nout,'(12i5)') dc%mapmesh

    WRITE (nout,*)

    WRITE (nout,'(a,i5)') ' spe : ', dc%spe
    WRITE (nout,'(a,i5)') ' epe : ', dc%epe
    WRITE (nout,'(a,i5)') ' d_nprocs : ', dc%d_nprocs

    WRITE (nout,*)

    WRITE (nout,'(a,i5)') ' nlon  : ', dc%nlon
    WRITE (nout,'(a,i5)') ' nlat  : ', dc%nlat
    WRITE (nout,'(a,i5)') ' nlev  : ', dc%nlev
    WRITE (nout,'(a,i5)') ' nm    : ', dc%nm
    WRITE (nout,'(a,12i5/(9x,12i5))') ' nmp   : ',dc%nmp
    WRITE (nout,'(a,12i5/(9x,12i5))') ' nnp   : ',dc%nnp
    WRITE (nout,'(a,i5)') ' nproca: ', dc%nproca
    WRITE (nout,'(a,i5)') ' nprocb: ', dc%nprocb

    WRITE (nout,*)

    WRITE (nout,'(i5,a)') dc%nglat, ' latitudes  in grid space'
    WRITE (nout,'(i5,a)') dc%nglon, ' longitudes in grid space'
    WRITE (nout,'(i5,a)') dc%nglpx, ' longitudes allocated'
    WRITE (nout,'(2i5,a)')dc%nglh,  ' latitudes on N/S hemisphere'
    WRITE (nout,'(i5,a)') dc%nglat*dc%nglon, ' grid points (total)'
    WRITE (nout,'(4(a,i5))') ' glatse: ', dc%glats(1), ' -', dc%glate(1), &
         ',   ', dc%glats(2), ' -', dc%glate(2)
    WRITE (nout,'(4(a,i5))') ' glonse: ', dc%glons(1), ' -', dc%glone(1), &
         ',   ', dc%glons(2), ' -', dc%glone(2)
    WRITE (nout,'(a,12i5/(9x,12i5))') ' glat  : ', dc% glat
    WRITE (nout,'(a,12i5/(9x,12i5))') ' glon  : ', dc% glon
    WRITE (nout,*)

    WRITE (nout,'(l4,a)') dc%lfused,  ' processor used in Fourier space'
    WRITE (nout,'(i5,a)') dc%nflat,   ' latitudes  in Fourier space'
    WRITE (nout,'(i5,a)') dc%nflevp1, ' levels+1 in Fourier space'
    WRITE (nout,'(i5,a)') dc%nflev,   ' levels in Fourier space'
    WRITE (nout,'(4(a,i5))') ' flat  : ', dc%flats(1), ' -', dc%flate(1), &
         ',   ', dc%flats(2), ' -', dc%flate(2)
    WRITE (nout,'(2(a,i5))') ' flev  : ', dc%flevs,    ' -', dc%fleve

    WRITE (nout,*)

    WRITE (nout,'(i5,a)') dc%nlm,     ' wave numbers in Legendre space'
    WRITE (nout,'(a,12i5/(9x,12i5))') ' lm   : ', dc%lm(:dc%nlm)
    WRITE (nout,'(a,12i5/(9x,12i5))') ' nlnp  : ', dc%nlnp(:dc%nlm)
    WRITE (nout,'(a,12i5/(9x,12i5))') ' nlmp  : ', dc%nlmp(:dc%nlm+1)
    WRITE (nout,'(i5,a)') dc%nlnm0,   ' coefficients for m=0'
    WRITE (nout,'(i5,a)') dc%lnsp,    ' spectral coefficients'
    WRITE (nout,'(i5,a)') dc%nllevp1, ' levels+1 in Legendre space'
    WRITE (nout,'(i5,a)') dc%nllev,   ' levels in Legendre space'
    WRITE (nout,'(2(a,i5))')          ' llev  : ', dc%llevs, ' -', dc%lleve

    WRITE (nout,*)

    WRITE (nout,'(i5,a)') dc%snsp,   ' coefficients'
    WRITE (nout,'(i5,a)') dc%snsp2,  ' coefficients times 2'
    WRITE (nout,'(i5,a)') dc%ssps,   ' first spectral coefficient'
    WRITE (nout,'(i5,a)') dc%sspe,   ' last spectral coefficient'

    WRITE (nout,'(l4,a)') dc%lfirstc, ' first global coefficient on this PE'
    WRITE (nout,'(i5,a)') dc%ifirstc, ' local index of first global coefficient'

    WRITE (nout,'(a,12i5/(9x,12i5))') ' np1   : ', dc%np1 
    WRITE (nout,'(a,12i5/(9x,12i5))') ' mymsp : ', dc%mymsp
    WRITE (nout,'(i5,a)') dc%nns ,    ' number of different n-values' 
    WRITE (nout,'(a,12i5/(9x,12i5))') ' nindex: ', dc%nindex

    WRITE (nout,'(i5,a)') dc%nsm ,    ' number of m wave numbers.'
    WRITE (nout,'(a,12i5/(9x,12i5))') ' sm    : ', dc%sm 
    !    WRITE (nout,'(a,12i5/(9x,12i5))') ' snmp  : ', dc%snmp
    WRITE (nout,'(a,12i5/(9x,12i5))') ' snnp  : ', dc%snnp
    WRITE (nout,'(a,12i5/(9x,12i5))') ' snn0  : ', dc%snn0
    WRITE (nout,'(i5,a)') dc%nsnm0 ,  ' coefficients for m=0'


  END SUBROUTINE print_decomposition

  SUBROUTINE mesh_map_init(option, isize, jsize, p, meshmap)

    ! all isize*jsize PEs are mapped to a 2-D logical mesh
    ! starting with PE with id p

    INTEGER :: option, isize, jsize, p
    INTEGER :: meshmap(1:isize,1:jsize)
    INTEGER :: i, j

    IF (option == 1) THEN
       ! row major ordering
       DO j = 1, jsize
          DO i = 1, isize
             meshmap(i,j) = (i-1) + (j-1)*isize + p
          END DO
       END DO
    ELSE IF (option == -1) THEN
       !column major ordering
       DO j = 1, jsize
          DO i = 1, isize
             meshmap(i,j) = (j-1) + (i-1)*jsize + p
          END DO
       END DO
    END IF

  END SUBROUTINE mesh_map_init

  SUBROUTINE mesh_index(p, isize, jsize, meshmap, idex, jdex)

    ! returns coordinates (idex,jdex) of PE with id p in logical mesh

    INTEGER :: p, isize, jsize, idex, jdex
    INTEGER :: meshmap(1:isize,1:jsize)
    INTEGER :: i, j
    LOGICAL :: lexit

    idex  = -1
    jdex  = -1
    lexit = .FALSE.

    DO j = 1, jsize
       DO i = 1, isize
          IF (meshmap(i,j) == p) THEN
             ! coordinates start at 1
             idex  = i
             jdex  = j
             lexit = .TRUE.
             EXIT
          END IF
       END DO
       IF (lexit) EXIT
    END DO
    ! check for successful completion of search
    IF ((idex == -1) .OR. (jdex == -1)) THEN
       CALL finish('mesh_index', &
            &            'Unable to find processor in meshmap array')
    END IF

  END SUBROUTINE mesh_index

END MODULE mo_decomposition
