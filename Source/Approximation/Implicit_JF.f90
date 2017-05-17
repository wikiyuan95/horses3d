!
!////////////////////////////////////////////////////////////////////////
!
!      Implicit_JF.f90
!      Created: 2017-03-XX XX:XX:XX -XXXX 
!      By:  Carlos Redondo (module for 2D) 
!           Andrés Rueda   (3D implementation and changes) -- to be listed here
!      Implicit module using BDF1 and Jacobian Free Newton-Krylov
!
!////////////////////////////////////////////////////////////////////////
MODULE Implicit_JF
   USE SMConstants,                 ONLY: RP                  
   USE DGSEMClass,                  ONLY: DGSem, ComputeTimeDerivative
   USE PhysicsStorage,              ONLY: N_EQN, N_GRAD_EQN
   USE JFNKClass,                   ONLY: JFNK_Integrator
   
   IMPLICIT NONE
   
   INTEGER                                            :: DimPrb
   INTEGER, DIMENSION(:), ALLOCATABLE                 :: Nx, Ny, Nz
   REAL(KIND = RP), DIMENSION(:), ALLOCATABLE         :: U_n
   TYPE(JFNK_Integrator)                              :: integrator
   TYPE(DGSem), POINTER                               :: p_sem
   
   PRIVATE
   PUBLIC      :: TakeBDFStep_JF
 
!========
 CONTAINS
!========
   
   SUBROUTINE TakeBDFStep_JF(sem, t , dt , maxResidual)
      TYPE(DGSem),TARGET,  INTENT(INOUT)           :: sem
      REAL(KIND=RP),       INTENT(IN)              :: t
      REAL(KIND=RP),       INTENT(IN)              :: dt
      !--------------------------------------------------------
      LOGICAL                                      :: isfirst = .TRUE.
      INTEGER                                      :: k
      
      REAL(KIND=RP) :: localMaxResidual(N_EQN), maxResidual(N_EQN)
      INTEGER       :: id, eq
      !--------------------------------------------------------
      
      IF (isfirst) THEN                                      
         isfirst = .FALSE.
         
         DimPrb = sem % NDOF
         ALLOCATE(U_n(1:Dimprb))
         
         !CALL integrator%Construct(DimPrb)                  !Constructs jfnk solver
         CALL integrator%Construct(DimPrb, pc = 'GMRES')     !Constructs jfnk solver using preconditioning (hardcoded: GMRES preco)
         p_sem => sem                                        !Makes sem visible by other routines whitin the module
      ENDIF
      
      CALL integrator%SetTime(t)                             ! Sets time at the beginning of iteration
      CALL integrator%SetDt(dt)                              ! Sets Dt in the time integrator
      
      CALL p_sem % GetQ(U_n)                                 ! Stores sem%mesh%elements(:)%Q into U_n    ! TODO: is this always necessary?                      
      CALL integrator%SetUn(U_n)                             ! Sets U_n  in the time integrator
      CALL integrator%SetTimeDerivative(DGTimeDerivative)    ! Sets DGTime derivative as Time derivative function in the integrtor
      CALL integrator%Integrate                              ! Performs the time step implicit integrator
      CALL integrator%GetUnp1(U_n)                           ! Gets U_n+1 and stores it in U n
      CALL p_sem % SetQ(U_n)                                 ! Stores U_n (with the updated U_n+1) into sem%Q  ! TODO: is this always necessary?
         
!
!     ----------------
!     Compute residual
!     ----------------
!
      maxResidual = 0.0_RP
      DO id = 1, SIZE( p_sem % mesh % elements )
         DO eq = 1 , N_EQN
            localMaxResidual(eq) = MAXVAL(ABS(sem % mesh % elements(id) % QDot(:,:,:,eq)))
            maxResidual(eq) = MAX(maxResidual(eq),localMaxResidual(eq))
         END DO
      END DO
         
   END SUBROUTINE TakeBDFStep_JF
!
!//////////////////////////////////////////////////////////////////////////////////////// 
!
   FUNCTION DGTimeDerivative(u,time) RESULT(F)
      REAL(KIND = RP), INTENT(IN)                  :: u(:)
      REAL(KIND = RP)                              :: F(size(u)) 
      REAL(KIND = RP)                              :: time
  
      CALL p_sem % SetQ(u)
      CALL ComputeTimeDerivative(p_sem,time)
      CALL p_sem % GetQdot(F)
    
   END FUNCTION DGTimeDerivative


END MODULE Implicit_JF
