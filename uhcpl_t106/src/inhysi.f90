!+ initializes constants for the vertical part of the semi-implicit
!  scheme.
!+ $Id: inhysi.f90,v 1.7 1999/07/01 08:40:08 m214030 Exp $

SUBROUTINE inhysi

  ! Description:
  !
  ! Initializes constants for the vertical part of the semi-implicit scheme.
  !
  ! Method:
  !
  ! Compute constants used in the implementation of the
  ! vertical part of the semi-implicit time scheme.
  !
  ! Input is from modules *mo_hyb* and *mo_semi_impl*.
  !
  ! Output is in module *mo_hyb*.
  !
  ! Externals:
  ! *pres* and *auxhyb* are called to calculate reference values.
  ! *pgrad* and *conteq* are called in the calculation
  !   of the gravity-wave matrix *bb.*
  !
  ! Authors:
  !
  ! A. J. Simmons, ECMWF, November 1981, original source
  ! L. Kornblueh, MPI, May 1998, f90 rewrite
  ! U. Schulzweida, MPI, May 1998, f90 rewrite
  ! 
  ! for more details see file AUTHORS
  !

  USE mo_control,       ONLY: nlev, nlevp1, twodt
  USE mo_semi_impl,     ONLY: apr, betadt, tr
  USE mo_hyb,           ONLY: aktlrd, altrcp, bb, delpr, ralphr, rdelpr, &
                              rdtr, rlnmar, rpr
  USE mo_constants,     ONLY: rcpd, rd
  USE mo_start_dataset, ONLY: nstart, nstep

  IMPLICIT NONE

  !  Local scalars: 
  REAL :: zdtim2, zdtime, zpr, zrcpd, zrd, ztr, ztwodt
  INTEGER :: jk, jkk
  LOGICAL :: loperm

  !  Local arrays: 
  REAL :: zdiv(nlev,nlev), zdlnps(nlev), zdt(nlev,nlev), zph(nlevp1), &
&      zpra(1), zrlnpr(nlev)

  !  External subroutines 
  EXTERNAL auxhyb, conteq, pgrad, pres


  !  Executable statements 

!-- 1. Set local values

  zrd = rd
  zrcpd = rcpd
  zpr = apr
  zpra(1) = zpr
  ztr = tr

!-- 2. Calculate rdtr, rpr, delpr, ralphr and rlnmar

  rpr = 1./zpr
  rdtr = zrd*ztr
  CALL pres(zph,1,zpra,1)
  CALL auxhyb(delpr,rdelpr,zrlnpr,ralphr,zph,1,1)

  rlnmar(1) = 0.
  DO jk = 2, nlev
    rlnmar(jk) = zrlnpr(jk) - ralphr(jk)
  END DO

!-- 3. Calculate aktlrd and altrcp

  DO jk = 1, nlev
    aktlrd(jk) = -zrcpd*ztr*zrlnpr(jk)*rdelpr(jk)
    altrcp(jk) = -zrcpd*ztr*ralphr(jk)
  END DO

!-- 4. Calculate gravity-wave matrix bb

  DO jk = 1, nlev

    DO jkk = 1, nlev
      zdiv(jk,jkk) = 0.
    END DO

    zdiv(jk,jk) = -1.

  END DO

  loperm = .FALSE.
  CALL conteq(zdt,nlev,zdlnps,zdiv,nlev,nlev,loperm)
  CALL pgrad(bb,zdt,nlev,zdlnps,nlev)

!-- 5. Scale arrays

  ! Divide *twodt* by 2 for first time step.
  ! *bb* is however always computed as for the first time step.

  ztwodt = twodt
  IF (nstep==nstart) ztwodt = ztwodt*.5
  zdtime = (ztwodt*.5)*betadt
  zdtim2 = zdtime*zdtime
  zdtim2 = ((twodt*.5)*.5*betadt)**2
  rpr = rpr*zdtime
  rdtr = rdtr*betadt

  DO jk = 1, nlev
    ralphr(jk) = ralphr(jk)*betadt
    rlnmar(jk) = rlnmar(jk)*betadt
  END DO

  DO jk = 1, nlev
    aktlrd(jk) = aktlrd(jk)*zdtime
    altrcp(jk) = altrcp(jk)*zdtime

    DO jkk = 1, nlev
      bb(jk,jkk) = bb(jk,jkk)*zdtim2

    END DO
  END DO

  RETURN
END SUBROUTINE inhysi
