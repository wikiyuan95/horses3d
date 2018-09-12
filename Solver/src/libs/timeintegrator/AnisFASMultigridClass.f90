!///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
!
!      FASMultigridClass.f90
!      Created: 2017-04-XX 10:006:00 +0100 
!      By: Andrés Rueda
!
!      Anisotropic version of the FAS Multigrid Class
!        As is, it is only valid for steady-state cases
!
!///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#include "Includes.h"
module AnisFASMultigridClass
   use SMConstants
   use ExplicitMethods
   use PhysicsStorage
   use TruncationErrorClass   , only: TruncationError_t, EstimateTruncationError, InitializeForTauEstimation, NON_ISOLATED_TE, ISOLATED_TE
   use InterpolationMatrices  , only: Interp3DArraysOneDir
   use MultigridTypes
   use DGSEMClass             , only: DGSem, ComputeTimeDerivative_f, MaxTimeStep
   use FTValueDictionaryClass , only: FTValueDictionary
#if defined(NAVIERSTOKES)
   use ManufacturedSolutions
#endif
   
   implicit none
   
   private
   public AnisFASMultigrid_t
   
   !--------------------------------------------------------------------------------
   ! Type for storing coarsening-direction-wise information for the multigrid scheme
   !--------------------------------------------------------------------------------
   type :: MGStorage_t
      type(DGSem)            , pointer           :: p_sem            ! Pointer to DGSem class variable of current system
      type(MGSolStorage_t), allocatable          :: Var(:)           ! Variables stored element-wise
   end type MGStorage_t
   
   !---------------------------------------------
   ! Main type for AnisFASMultigridClass (THE SOLVER)
   !---------------------------------------------
   type :: AnisFASMultigrid_t
      type(MGStorage_t)                          :: MGStorage(3)          ! Storage of important variables for multigrid. Indices are for coarsening direction (x, y, z)
      type(AnisFASMultigrid_t)   , pointer       :: Child                 ! Next coarser multigrid solver
      type(AnisFASMultigrid_t)   , pointer       :: Parent                ! Next finer multigrid solver
      
      contains
         procedure                                  :: construct
         procedure                                  :: solve
         procedure                                  :: destruct      
   end type AnisFASMultigrid_t
   
!
!  ----------------
!  Module variables
!  ----------------
!
   procedure(SmoothIt_t), pointer :: SmoothIt
   
   !! Parameters
   integer, parameter :: MAX_SWEEPS_DEFAULT = 10000
   
   !! Variables
   integer        :: MGlevels(3)    ! Total number of multigrid levels        
   integer        :: MaxN(3)        ! Maximum polynomial order in every direction
   integer        :: NMIN           ! Minimum polynomial order allowed
   integer        :: deltaN         !                                         ! TODO: deltaN(3)
   integer        :: nelem          ! Number of elements (this is a p-multigrid implementation)
   integer        :: SweepNumPre    ! Number of sweeps pre-smoothing
   integer        :: SweepNumPost   ! Number of sweeps post-smoothing
   integer        :: SweepNumCoarse ! Number of sweeps on coarsest level
   integer        :: MaxSweeps      ! Maximum number of sweeps in a smoothing process
   logical        :: PostFCycle,PostSmooth ! Post smoothing options
   logical        :: MGOutput       ! Display output?
   logical        :: ManSol         ! Does this case have manufactured solutions?
   logical        :: SmoothFine     ! 
   logical        :: EstimateTE = .FALSE. ! Estimate the truncation error!
   logical        :: Compute_dt
   real(kind=RP)  :: SmoothFineFrac ! Fraction that must be smoothed in fine before going to coarser level
   real(kind=RP)  :: cfl            ! Advective cfl number
   real(kind=RP)  :: dcfl           ! Diffusive cfl number
   real(kind=RP)  :: dt             ! dt
   character(len=LINE_LENGTH)    :: meshFileName
   
   logical                    :: AnisFASestimator  ! Whether this is an AnisFAS estimator or not
   
!========
 contains
!========
!
!///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
!
   subroutine construct(this,controlVariables,sem,estimator,NMINestim)
      use StopwatchClass
      implicit none
      !-----------------------------------------------------------
      class(AnisFASMultigrid_t), intent(inout), target :: this              !<> Anisotropic FAS multigrid solver to be constructed
      type(FTValueDictionary)  , intent(in)            :: controlVariables  !<  Input variables
      type(DGSem)              , intent(in)   , target :: sem               !<  Fine sem class
      logical                  , intent(in) , optional :: estimator         !<  Is this anisotropic FAS only an estimator?
      integer                  , intent(in) , optional :: NMINestim         !<  NMIN for tau-estimation
      !-----------------------------------------------------------
      integer                    :: Dir               ! Direction of coarsening
      integer                    :: UserMGlvls        ! User defined number of MG levels
      character(len=LINE_LENGTH) :: PostSmoothOptions
      !-----------------------------------------------------------
      
      call Stopwatch % Pause("Solver")
      call Stopwatch % Start("Preprocessing")
!
!     ----------------------------------
!     Read important variables from file
!     ----------------------------------
!
      if ( present(estimator) ) then
         AnisFASestimator = estimator
      else
         AnisFASestimator = .FALSE.
      end if
      
      if (.NOT. controlVariables % containsKey("multigrid levels")) then
         print*, 'Fatal error: "multigrid levels" keyword is needed by the AnisFASMultigrid solver'
         STOP
      end if
      
      UserMGlvls = controlVariables % IntegerValueForKey("multigrid levels")
      
      if (AnisFASestimator) then
         deltaN = 1
         SweepNumPre  = 0
         SweepNumPost = 0
         SweepNumCoarse = 0
         PostFCycle = .FALSE.
         PostSmooth = .FALSE.
         SmoothFine = .FALSE.
      else
         ! Read deltaN
         if (controlVariables % containsKey("delta n")) then
            deltaN = controlVariables % IntegerValueForKey("delta n")
         else
            deltaN = 1
         end if
         
         ! Read number of sweeps
         if (controlVariables % containsKey("mg sweeps pre" ) .AND. &
             controlVariables % containsKey("mg sweeps post") ) then
            SweepNumPre  = controlVariables % IntegerValueForKey("mg sweeps pre")
            SweepNumPost = controlVariables % IntegerValueForKey("mg sweeps post")
         elseif (controlVariables % containsKey("mg sweeps")) then
            SweepNumPre  = controlVariables % IntegerValueForKey("mg sweeps")
            SweepNumPost = SweepNumPre
         else
            SweepNumPre  = 1
            SweepNumPost = 1
         end if
         
         ! Read number of sweeps in the coarsest leveñ
         if (controlVariables % containsKey("mg sweeps coarsest")) then
            SweepNumCoarse = controlVariables % IntegerValueForKey("mg sweeps coarsest")
         else
            SweepNumCoarse = (SweepNumPre + SweepNumPost) / 2
         end if
         
         ! Read post-smoothing options
         PostSmoothOptions = controlVariables % StringValueForKey("postsmooth option",LINE_LENGTH)
         if (trim(PostSmoothOptions) == 'f-cycle') then
            PostFCycle = .TRUE.
         elseif (trim(PostSmoothOptions) == 'smooth') then
            PostSmooth = .TRUE.
         end if
         
         if (controlVariables % containsKey("smooth fine")) then
            SmoothFine = .TRUE.
            SmoothFineFrac = controlVariables % doublePrecisionValueForKey("smooth fine")
         else
            SmoothFine = .FALSE.
         end if
      end if
      
      select case (controlVariables % StringValueForKey("mg smoother",LINE_LENGTH))
         case('RK3')  ; SmoothIt => TakeRK3Step
         case('SIRK')
            !! SmoothIt => TakeSIRKStep
            error stop ':: SIRK smoother not implemented yet'
         case default 
            write(STD_OUT,*) '"mg smoother" not recognized. Defaulting to RK3.'
            SmoothIt => TakeRK3Step
      end select
      
      if (controlVariables % containsKey("max mg sweeps")) then
         MaxSweeps = controlVariables % IntegerValueForKey("max mg sweeps")
      else
         MaxSweeps = MAX_SWEEPS_DEFAULT
      end if
      
!     Read cfl and dcfl numbers
!     -------------------------
      if (controlVariables % containsKey("cfl")) then
#if defined(NAVIERSTOKES)
         Compute_dt = .TRUE.
         cfl = controlVariables % doublePrecisionValueForKey("cfl")
         if (flowIsNavierStokes) then
            if (controlVariables % containsKey("dcfl")) then
               dcfl       = controlVariables % doublePrecisionValueForKey("dcfl")
            else
               ERROR STOP '"cfl" and "dcfl", or "dt", keywords must be specified for the FAS integrator'
            end if
         end if
#elif defined(CAHNHILLIARD)
         print*, "Error, use fixed time step to solve Cahn-Hilliard equations"
         errorMessage(STD_OUT)
         stop
#endif
      elseif (controlVariables % containsKey("dt")) then
         Compute_dt = .FALSE.
         dt = controlVariables % doublePrecisionValueForKey("dt")
      else
         ERROR STOP '"cfl" and "dcfl" if Navier-Stokes) or "dt" keywords must be specified for the FAS integrator'
      end if
      
!
!     -----------------------
!     Update module variables
!     -----------------------
!
      MaxN(1) = MAXVAL(sem%Nx)
      MaxN(2) = MAXVAL(sem%Ny)
      MaxN(3) = MAXVAL(sem%Nz)
      
!
!     If 3D meshes are not conforming on boundaries, we must have N >= 2
!        (and AnisFAS ALWAYS creates anisotropic meshes - almost guaranteed to be nonconforming - change?)
!     --------------------------------------------------
      
      if (AnisFASestimator) then
         if ( present(NMINestim) ) then
            NMIN = NMINestim
         else
            NMIN = 1
         end if
      elseif (sem % mesh % meshIs2D) then
         NMIN = 1
      else 
         NMIN = 2
      end if
      
      MGlevels(1)  = MIN(MaxN(1) - NMIN + 1,UserMGlvls)
      MGlevels(2)  = MIN(MaxN(2) - NMIN + 1,UserMGlvls)
      MGlevels(3)  = MIN(MaxN(3) - NMIN + 1,UserMGlvls)
      
      write(STD_OUT,*) 'Constructing anisotropic FAS Multigrid'
      write(STD_OUT,*) 'Number of levels:', MGlevels
      
      MGOutput       = controlVariables % logicalValueForKey("multigrid output")
      plotInterval   = controlVariables % integerValueForKey("output interval")
      ManSol         = sem % ManufacturedSol
      
      this % MGStorage(1) % p_sem => sem
      this % MGStorage(2) % p_sem => sem
      this % MGStorage(3) % p_sem => sem
      
      nelem = SIZE(sem % mesh % elements)  ! Same for all levels (only p-multigrid)
!
!     -----------------------------
!     Construct linked solvers list
!     -----------------------------
!
      call ConstructLinkedSolvers(this, MAXVAL(MGlevels))
!
!     -----------------------------------------------------------------------
!     Construct interpolation operators and DGSem classes for every subsolver
!     -----------------------------------------------------------------------
!
      meshFileName = controlVariables % stringValueForKey("mesh file name", requestedLength = LINE_LENGTH)
      do Dir = 1, 3
         call ConstructFASInOneDirection(this, MGlevels(Dir), controlVariables, Dir)   ! TODO: change argument to meshFileName
      end do
      
      call Stopwatch % Pause("Preprocessing")
      call Stopwatch % Start("Solver")
   end subroutine construct
!
!///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
!
!  --------------------------------------------------
!  Subroutine for creating the linked list of solvers
!  --------------------------------------------------
   recursive subroutine ConstructLinkedSolvers(Solver, lvl)
      implicit none
      !----------------------------------------------
      type(AnisFASMultigrid_t), TARGET  :: Solver           !<> Current solver
      integer                       :: lvl              !<  Current multigrid level
      !----------------------------------------------
!
!     -------------------------------------
!     Create child if not on coarsest level
!     -------------------------------------
!
      if (lvl > 1) then
         allocate  (Solver % Child)       ! TODO: Remove from here!!!
         Solver % Child % Parent => Solver
         
         call ConstructLinkedSolvers(Solver % Child, lvl - 1)
      end if
      
   end subroutine ConstructLinkedSolvers
!
!///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
!
!  ----------------------------------------------------------------------
!  Subroutine for creating interpolation operators, multigrid storage and 
!  DGSem classes for every subsolver in one of the three directions
!  ----------------------------------------------------------------------
   recursive subroutine ConstructFASInOneDirection(Solver, lvl, controlVariables,Dir)
!~       use BoundaryConditionFunctions ! TODO: needed=??
      implicit none
      type(AnisFASMultigrid_t), TARGET  :: Solver           !<> Current solver
      integer                       :: lvl              !<  Current multigrid level
      type(FTValueDictionary)       :: controlVariables !<  Control variables (for the construction of coarse sems
      integer                       :: Dir              !<  Coarsening direction
      !----------------------------------------------
      integer, dimension(:), pointer :: N1x,N1y,N1z            !   Order of approximation for every element in current solver
      integer, dimension(:), pointer :: N1
      integer, dimension(nelem,3)    :: N2                     !   Order of approximation for every element in child solver
      integer                        :: i,j,k, iEl             !   Counter
      logical                        :: success                ! Did the creation of sem succeed?
      !----------------------------------------------
      !
      integer :: Nxyz(3), fd, l
      integer  :: nEqn

#if defined(NAVIERSTOKES)
      nEqn = NCONS
#endif
      !--------------------------
      ! Allocate variable storage
      !--------------------------

      allocate (Solver % MGStorage(Dir) % Var(nelem))
      
      associate ( p_sem => Solver % MGStorage(Dir) % p_sem )
      
      ! Define N1x, N1y and N1z according to refinement direction
      N1x => p_sem % Nx
      N1y => p_sem % Ny
      N1z => p_sem % Nz
   
!$omp parallel do
      do k = 1, nelem
         allocate(Solver % MGStorage(Dir) % Var(k) % Q    (nEqn,0:N1x(k),0:N1y(k),0:N1z(k)))
         allocate(Solver % MGStorage(Dir) % Var(k) % E    (nEqn,0:N1x(k),0:N1y(k),0:N1z(k)))
         allocate(Solver % MGStorage(Dir) % Var(k) % S    (nEqn,0:N1x(k),0:N1y(k),0:N1z(k)))
         allocate(Solver % MGStorage(Dir) % Var(k) % Scase(nEqn,0:N1x(k),0:N1y(k),0:N1z(k)))
         
         Solver % MGStorage(Dir) % Var(k) % Scase = 0._RP
      end do   
!$omp end parallel do
!
!     -----------------------------------------------------
!     Fill source term if required (manufactured solutions)
!     -----------------------------------------------------
!
#if defined(NAVIERSTOKES)
      if (ManSol) then
         do iEl = 1, nelem
            
            do k=0, N1z(iEl)
               do j=0, N1y(iEl)
                  do i=0, N1x(iEl)
                     if (flowIsNavierStokes) then
                        call ManufacturedSolutionSourceNS(p_sem % mesh % elements(iEl) % geom % x(:,i,j,k), &
                                                          0._RP, &
                                                          Solver % MGStorage(Dir) % Var(iEl) % Scase (i,j,k,:)  )
                     else
                        call ManufacturedSolutionSourceEuler(p_sem % mesh % elements(iEl) % geom % x(:,i,j,k), &
                                                             0._RP, &
                                                             Solver % MGStorage(Dir) % Var(iEl) % Scase (i,j,k,:)  )
                     end if
                  end do
               end do
            end do
         end do
      end if
#endif
      
      if (lvl > 1) then
         associate (Child_p => Solver % Child)
!
!        -----------------------------------------------
!        Allocate restriction and prolongation operators
!        -----------------------------------------------
!
         select case (Dir)
            case(1); N1 => N1x
            case(2); N1 => N1y
            case(3); N1 => N1z
         end select
         
!
!        ---------------------------------------------
!        Create restriction and prolongation operators
!        ---------------------------------------------
!
         ! First we assign the parent's orders to the child
         N2(:,1) = N1x
         N2(:,2) = N1y
         N2(:,3) = N1z
         
         ! Now we create the interpolation operators and change the corresponding orders in the child
         do k=1, nelem
            call CreateInterpolationOperators(N1(k),N2(k,Dir), MaxN(Dir), MGlevels(Dir), lvl-1, DeltaN, Solver % MGStorage(Dir) % p_sem % nodes)
         end do
!
!        -----------------------------------------------------------
!        Create DGSEM class for child in the corresponding direction
!        -----------------------------------------------------------
!
         allocate (Child_p % MGStorage(Dir) % p_sem)
         
         if (AnisFASestimator) Child_p % MGStorage(Dir) % p_sem % mesh % ignoreBCnonConformities = .TRUE.
         
         call Child_p % MGStorage(Dir) % p_sem % construct &
                                          (controlVariables  = controlVariables,                                         &
                                           Nx_ = N2(:,1),    Ny_ = N2(:,2),    Nz_ = N2(:,3),                            &
                                           success = success,                                                            &
                                           ChildSem = .TRUE. )
         if (.NOT. success) ERROR STOP "Multigrid: Problem creating coarse solver."
         if (AnisFASestimator) Child_p % MGStorage(Dir) % p_sem % mesh % ignoreBCnonConformities = .FALSE.
         
         call ConstructFASInOneDirection(Solver % Child, lvl - 1, controlVariables,Dir)
         
         end associate
      end if
      
      end associate
   end subroutine ConstructFASInOneDirection
!
!///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
!
!  ---------------------------------------------
!  Driver of the FAS multigrid solving procedure
!  ---------------------------------------------
   subroutine solve(this,timestep,t,ComputeTimeDerivative,ComputeTimeDerivativeIsolated,TE,TEType)
      implicit none
      class(AnisFASMultigrid_t)        , intent(inout) :: this       !<> The AnisFAS
      integer                          , intent(in)    :: timestep   !<  Current time step
      real(kind=RP)                    , intent(in)    :: t          !<  Current simulation time
      procedure(ComputeTimeDerivative_f)                       :: ComputeTimeDerivative
      procedure(ComputeTimeDerivative_f), optional             :: ComputeTimeDerivativeIsolated
      type(TruncationError_t), optional, intent(inout) :: TE(:)      !<> Truncation error for all elements. If present, the multigrid solver also estimates the TE
      integer                , optional, intent(in)    :: TEType     !<  Truncation error type (either NON_ISOLATED_TE or ISOLATED_TE)
      !-------------------------------------------------
      character(len=LINE_LENGTH)              :: FileName
      integer                                 :: Dir
      !-------------------------------------------------
      
!
!     -------------------------------------------------
!     Prepare everything for p adaptation (if required)
!     -------------------------------------------------
!
      if (PRESENT(TE)) then
         EstimateTE = .TRUE.
         if (present(TEType)) then
            call InitializeForTauEstimation(TE,this % MGStorage(1) % p_sem,TEType, ComputeTimeDerivative, ComputeTimeDerivativeIsolated)
         else ! using NON_ISOLATED_TE by default
            call InitializeForTauEstimation(TE,this % MGStorage(1) % p_sem,NON_ISOLATED_TE, ComputeTimeDerivative, ComputeTimeDerivativeIsolated)
         end if
      else
         EstimateTE = .FALSE.
      end if
      
      ThisTimeStep = timestep
!
!
!     ---------------------------------------------------------
!     Perform a v-cycle in each direction (x,y,z)
!        (inside, the tau estimation is performed if requested)
!     ---------------------------------------------------------
!
      do Dir = 1, 3
         call FASVCycle(this,t,MGlevels(Dir),Dir,TE, ComputeTimeDerivative)
      end do
      
      !! Finish up
      
      EstimateTE = .FALSE.
   end subroutine solve
!
!///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
!
!  -----------------------------------------
!  Recursive subroutine to perform a v-cycle
!  -----------------------------------------
   recursive subroutine FASVCycle(this,t,lvl,Dir,TE, ComputeTimeDerivative)
      implicit none
      !----------------------------------------------------------------------------
      class(AnisFASMultigrid_t), intent(inout), TARGET :: this    !<  Current level solver
      real(kind=RP)                        :: t       !<  Simulation time
      integer                              :: lvl     !<  Current multigrid level
      integer                              :: Dir     !<  Direction in which multigrid will be performed (x:1, y:2, z:3)
      type(TruncationError_t)              :: TE(:)   !>  Variable containing the truncation error estimation
      procedure(ComputeTimeDerivative_f)           :: ComputeTimeDerivative
      !----------------------------------------------------------------------------
      integer                       :: iEl        !Element counter
      integer                       :: N1(3)          !Polynomial orders in origin solver       (Attention: the origin can be parent or child)
      integer                       :: N2(3)          !Polynomial orders in destination solver  (Attention: the origin can be parent or child)
      real(kind=RP)                 :: PrevRes
      integer                       :: sweepcount
      integer                       :: NumOfSweeps
      integer                       :: nEqn
      !----------------------------------------------------------------------------

#if defined(NAVIERSTOKES)
      nEqn = NCONS
#endif
!
!     -----------
!     Definitions
!     -----------
!
      associate (p_sem => this % MGStorage(Dir) % p_sem, &
                 Var   => this % MGStorage(Dir) % Var )
!
!     -----------------------
!     Pre-smoothing procedure
!     -----------------------
!
      if (lvl == 1) then
         NumOfSweeps = SweepNumCoarse
      else
         NumOfSweeps = SweepNumPre
      end if
      
      sweepcount = 0
      DO
         do iEl = 1, NumOfSweeps
            if (Compute_dt) dt = MaxTimeStep(p_sem, cfl, dcfl )
            call SmoothIt(p_sem % mesh, p_sem % particles, t, dt, ComputeTimeDerivative )
         end do
         sweepcount = sweepcount + 1
         if (MGOutput) call PlotResiduals( lvl, sweepcount*NumOfSweeps , p_sem % mesh )
         
         if (SmoothFine .AND. lvl > 1) then
            call MGRestrictToChild(this,Dir,lvl,t,TE, ComputeTimeDerivative)
            associate(Childp_sem => this % Child % MGStorage(Dir) % p_sem)
            call ComputeTimeDerivative(Childp_sem % mesh, Childp_sem % particles, t, CTD_IGNORE_MODE)
            end associate
            
            if (MAXVAL(ComputeMaxResiduals(p_sem % mesh)) < SmoothFineFrac * MAXVAL(ComputeMaxResiduals &
                                                            (this % Child % MGStorage(Dir) % p_sem % mesh))) exit
         else
            exit
         end if
      end do
      PrevRes = MAXVAL(ComputeMaxResiduals(p_sem % mesh))
      
!~       if (MGOutput) call PlotResiduals( lvl , p_sem )
      
      if (lvl > 1) then
         
         associate (Childp_sem => this % Child % MGStorage(Dir) % p_sem, &
                    ChildVar   => this % Child % MGStorage(Dir) % Var )
         
         if (.not. SmoothFine) call MGRestrictToChild(this,Dir,lvl,t,TE, ComputeTimeDerivative)
!
!        --------------------
!        Perform V-Cycle here
!        --------------------
!
         call FASVCycle(this % Child,t, lvl-1, Dir,TE, ComputeTimeDerivative)
!
!        -------------------------------------------
!        Interpolate coarse-grid error to this level
!        -------------------------------------------
!
!$omp parallel
!$omp do private(N1,N2) schedule(runtime)
         do iEl = 1, nelem
            N1 = Childp_sem % mesh % elements(iEl) % Nxyz
            N2 =      p_sem % mesh % elements(iEl) % Nxyz
            
            call Interp3DArraysOneDir(nEqn, &
                                      N1, ChildVar(iEl) % E, &
                                      N2, Var     (iEl) % E, &
                                      Dir)
         end do
!$omp end do
!$omp barrier
!
!        -----------------------------------------------
!        Correct solution with coarse-grid approximation
!        -----------------------------------------------
!
!$omp do schedule(runtime)
         do iEl = 1, nelem
            p_sem % mesh % elements(iEl) % storage % Q = p_sem % mesh % elements(iEl) % storage % Q + Var(iEl) % E
         end do
!$omp end do
!$omp end parallel
         end associate
      end if
!
!     ------------------------
!     Post-smoothing procedure
!     ------------------------
!
      if (lvl == 1) then
         NumOfSweeps = SweepNumCoarse
      else
         NumOfSweeps = SweepNumPost
      end if
      
      sweepcount=0
      DO
         
         do iEl = 1, NumOfSweeps
            if (Compute_dt) dt = MaxTimeStep(p_sem, cfl, dcfl )
            call SmoothIt(p_sem % mesh, p_sem % particles, t, dt, ComputeTimeDerivative )
         end do

         sweepcount = sweepcount + 1
         if (MGOutput) call PlotResiduals( lvl,sweepcount*NumOfSweeps, p_sem % mesh)
         
         if (PostSmooth .or. PostFCycle) then
            if (MAXVAL(ComputeMaxResiduals(p_sem % mesh)) < PrevRes) exit
         else
            exit
         end if
         
      end do
!~       if (MGOutput) call PlotResiduals( lvl , p_sem )
!
!     -------------------------
!     Compute coarse-grid error
!     -------------------------
!
      if (lvl < MGlevels(Dir)) then
!$omp parallel do schedule(runtime)
         do iEl = 1, nelem
            Var(iEl) % E = p_sem % mesh % elements(iEl) % storage % Q - Var(iEl) % Q
         end do
!$omp end parallel do
      end if
      
      end associate
   end subroutine FASVCycle
!
!///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
!
!  ------------------------------------------
!  Subroutine that restricts to child..... 
!  ------------------------------------------
   subroutine MGRestrictToChild(this,Dir,lvl,t,TE, ComputeTimeDerivative)
      implicit none
      !-------------------------------------------------------------
      class(AnisFASMultigrid_t), TARGET, intent(inout) :: this     !<  Current level solver
      integer                , intent(in)    :: Dir
      integer                , intent(in)    :: lvl
      real(kind=RP)          , intent(in)    :: t
      type(TruncationError_t), intent(inout) :: TE(:)   !>  Variable containing the truncation error estimation 
      procedure(ComputeTimeDerivative_f)             :: ComputeTimeDerivative
      !-------------------------------------------------------------
      integer  :: iEl
      integer  :: N1(3)
      integer  :: N2(3)
      !-------------------------------------------------------------
#if defined(NAVIERSTOKES)      

      associate(  p_sem      => this % MGStorage(Dir) % p_sem        , &
                  Var        => this % MGStorage(Dir) % Var          , &
                  Childp_sem => this % Child % MGStorage(Dir) % p_sem, &
                  ChildVar   => this % Child % MGStorage(Dir) % Var    )
      
!$omp parallel
!$omp do private(N1,N2) schedule(runtime)
      do iEl = 1, nelem
         N1 = p_sem      % mesh % elements(iEl) % Nxyz
         N2 = Childp_sem % mesh % elements(iEl) % Nxyz
         
!
!        Restrict solution
!        -----------------
         
         call Interp3DArraysOneDir(NCONS, &
                                   N1, p_sem      % mesh % elements(iEl) % storage % Q, &
                                   N2, Childp_sem % mesh % elements(iEl) % storage % Q, &
                                   Dir)
!
!        Restrict residual
!        -----------------
            
         call Interp3DArraysOneDir(NCONS, &
                                   N1, p_sem % mesh % elements(iEl) % storage % Qdot, &
                                   N2, ChildVar(iEl) % S, &
                                   Dir)
      end do
!$omp end do

!
!     **********************************************************************
!     **********************************************************************
!              Now arrange all the storage in the child solver (and estimate TE if necessary...)
!     **********************************************************************
!     **********************************************************************

!
!     ------------------------------------
!     Copy fine grid solution to MGStorage
!        ... and clear source term
!     ------------------------------------
!
!$omp barrier
!$omp do schedule(runtime)
      do iEl = 1, nelem
         ChildVar(iEl) % Q = Childp_sem % mesh % elements(iEl) % storage % Q
         Childp_sem   % mesh % elements(iEl) % storage % S_NS = 0._RP
      end do
!$omp end do
!$omp end parallel
!
!     -------------------------------------------
!     If not on finest level, correct source term
!     -------------------------------------------
!
      if (EstimateTE) then
         if ( TE(1) % TruncErrorType == NON_ISOLATED_TE) then ! This assumes that the truncation error type is the same in all elements
            call EstimateTruncationError(TE,Childp_sem,t,ChildVar,Dir)
         elseif ( TE(1) % TruncErrorType == ISOLATED_TE) then
            call EstimateTruncationError(TE,Childp_sem,t,ChildVar,Dir)
            call ComputeTimeDerivative(Childp_sem % mesh,Childp_sem % particles, t, CTD_IGNORE_MODE)
         end if
      else
         call ComputeTimeDerivative(Childp_sem % mesh, Childp_sem % particles, t, CTD_IGNORE_MODE)
      end if
      
!$omp parallel do schedule(runtime)
      do iEl = 1, nelem
         Childp_sem % mesh % elements(iEl) % storage % S_NS = ChildVar(iEl) % S - Childp_sem % mesh % elements(iEl) % storage % Qdot
      end do
!$omp end parallel do
      
      end associate
#endif      
   end subroutine MGRestrictToChild
!
!///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
!
!  -----------------------------------------------
!  Subroutine that destructs an AnisFAS integrator
!  -----------------------------------------------
   subroutine destruct(this)       
      implicit none
      !-----------------------------------------------------------
      class(AnisFASMultigrid_t), intent(inout) :: this
      !-----------------------------------------------------------
      integer                              :: Dir
      !-----------------------------------------------------------
      
      do Dir=1, 3
         call DestructStorageOneDir(this,MGlevels(Dir),Dir)
      end do
      
      call FinalizeDestruction(this,MAXVAL(MGlevels))
      
   end subroutine destruct
!
!///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
!
   recursive subroutine DestructStorageOneDir(Solver,lvl,Dir)
      implicit none
      !-----------------------------------------------------------
      class(AnisFASMultigrid_t), intent(inout) :: Solver
      integer                              :: lvl
      integer                              :: Dir
      !-----------------------------------------------------------
      
      !-----------------------------------------------------------
      
      ! First go to finest level (in this direction)
      if (lvl > 1) call DestructStorageOneDir(Solver % Child,lvl-1,Dir)
      
      !Destruct Multigrid storage
      deallocate (Solver % MGStorage(Dir) % Var) ! allocatable components are automatically deallocated
      
      if (lvl < MGlevels(Dir)) then
         call Solver % MGStorage(Dir) % p_sem % destruct()
         deallocate (Solver % MGStorage(Dir) % p_sem)
      else
         nullify    (Solver % MGStorage(Dir) % p_sem)
      end if
      
      
   end subroutine DestructStorageOneDir
!
!///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
!
   recursive subroutine FinalizeDestruction(Solver,lvl)
      implicit none
      !-----------------------------------------------------------
      class(AnisFASMultigrid_t), intent(inout) :: Solver
      integer                              :: lvl
      !-----------------------------------------------------------
      
      if (lvl > 1) then
         call FinalizeDestruction(Solver % Child,lvl-1)
         deallocate (Solver % Child)
      end if
      
      if (lvl < MAXVAL(MGlevels)) NULLifY(Solver % Parent)
      
   end subroutine FinalizeDestruction
!
!///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
!
   
end module AnisFASMultigridClass