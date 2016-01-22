!
!////////////////////////////////////////////////////////////////////////
!
!      NSLite3D.f90
!      Created: May 21, 2015 at 12:56 PM 
!      By: David Kopriva  
!
!////////////////////////////////////////////////////////////////////////
!
      Module mainKeywordsModule
         IMPLICIT NONE 
         INTEGER, PARAMETER :: KEYWORD_LENGTH = 132
         CHARACTER(LEN=KEYWORD_LENGTH), PARAMETER :: machNumberKey           = "mach number"
         CHARACTER(LEN=KEYWORD_LENGTH), PARAMETER :: reynoldsNumberKey       = "reynolds number"
         CHARACTER(LEN=KEYWORD_LENGTH), PARAMETER :: aoaThetaKey             = "aoa theta"
         CHARACTER(LEN=KEYWORD_LENGTH), PARAMETER :: aoaPhiKey               = "aoa phi"
         CHARACTER(LEN=KEYWORD_LENGTH), PARAMETER :: flowIsNavierStokesKey   = "flowisnavierstokes"
         CHARACTER(LEN=KEYWORD_LENGTH), PARAMETER :: polynomialOrderKey      = "polynomial order"
         CHARACTER(LEN=KEYWORD_LENGTH), PARAMETER :: cflKey                  = "cfl"
         CHARACTER(LEN=KEYWORD_LENGTH), PARAMETER :: meshFileNameKey         = "mesh file name"
         CHARACTER(LEN=KEYWORD_LENGTH), PARAMETER :: restartKey              = "restart"
         CHARACTER(LEN=KEYWORD_LENGTH), PARAMETER :: restartFileNameKey      = "restart file name"
         CHARACTER(LEN=KEYWORD_LENGTH), PARAMETER :: numberOfTimeStepsKey    = "number of time steps"
         CHARACTER(LEN=KEYWORD_LENGTH), PARAMETER :: outputIntervalKey       = "output interval"
         CHARACTER(LEN=KEYWORD_LENGTH), PARAMETER :: convergenceToleranceKey = "convergence tolerance"
         CHARACTER(LEN=KEYWORD_LENGTH), PARAMETER :: numberOfPlotPointsKey   = "number of plot points"
         CHARACTER(LEN=KEYWORD_LENGTH), PARAMETER :: numberOfBoundariesKey   = "number of boundaries"
         CHARACTER(LEN=KEYWORD_LENGTH), PARAMETER :: plotFileNameKey         = "plot file name"
         CHARACTER(LEN=KEYWORD_LENGTH), DIMENSION(15) :: mainKeywords =  [machNumberKey,           &
                                                                          reynoldsNumberKey,       &
                                                                          aoaThetaKey,             &
                                                                          aoaPhiKey,               &
                                                                          flowIsNavierStokesKey,   &
                                                                          polynomialOrderKey,      &
                                                                          cflKey,                  &
                                                                          meshFileNameKey,         &
                                                                          restartKey,              &
                                                                          restartFileNameKey,      &
                                                                          numberOfTimeStepsKey,    &
                                                                          outputIntervalKey,       &
                                                                          convergenceToleranceKey, &
                                                                          numberOfPlotPointsKey,   &
                                                                          plotFileNameKey]
      END MODULE mainKeywordsModule
!
!////////////////////////////////////////////////////////////////////////
!
      PROGRAM NSLite3DMain
      
      USE SMConstants
      USE FTTimerClass
      USE PhysicsStorage
      USE SharedBCModule
      USE DGSEMPlotterClass
      USE DGSEMClass
      USE BoundaryConditionFunctions
      USE TimeIntegratorClass
      USE UserDefinedFunctions
      USE mainKeywordsModule
      
      IMPLICIT NONE
!
!     ------------
!     Declarations
!     ------------
!
      TYPE( FTValueDictionary)            :: controlVariables
      TYPE( DGSem )                       :: sem
      TYPE( FTTimer )                     :: stopWatch
      TYPE( DGSEMPlotter )      , POINTER :: plotter      => NULL()
      CLASS( PlotterDataSource ), POINTER :: plDataSource => NULL()
      TYPE( RKTimeIntegrator )            :: timeIntegrator
      
      REAL(KIND=RP)                       :: dt, cfl
      
      LOGICAL                             :: success
      INTEGER                             :: plotUnit, restartUnit
      INTEGER, EXTERNAL                   :: UnusedUnit
      EXTERNAL                            :: externalStateForBoundaryName
      EXTERNAL                            :: ExternalGradientForBoundaryName
!
!     ---------------
!     Initializations
!     ---------------
!
      CALL controlVariables % initWithSize(16)
      CALL stopWatch % init()
      CALL UserDefinedStartup
      CALL ConstructSharedBCModule
      
      CALL ReadInputFile( controlVariables )
      CALL CheckInputIntegrity(controlVariables, success)
      IF(.NOT. success)   ERROR STOP "Control file reading error"
      
!
!     ----------------
!     Set up the DGSEM
!     ----------------
!      
      CALL ConstructPhysicsStorage( controlVariables % doublePrecisionValueForKey(machNumberKey),     &
                                    controlVariables % doublePrecisionValueForKey(reynoldsNumberKey), &
                                    0.72_RP,                                                          &
                                    controlVariables % doublePrecisionValueForKey(aoaThetaKey),       &
                                    controlVariables % doublePrecisionValueForKey(aoaPhiKey),         &
                                    controlVariables % logicalValueForKey(flowIsNavierStokesKey) )
                                    
      CALL sem % construct(polynomialOrder   = controlVariables % integerValueForKey(polynomialOrderKey),&
                           meshFileName      = controlVariables % stringValueForKey(meshFileNameKey,     &
                                                                        requestedLength = LINE_LENGTH),  &
                           externalState     = externalStateForBoundaryName,                             &
                           externalGradients = ExternalGradientForBoundaryName,                          &
                           success           = success)
                           
      IF(.NOT. success)   ERROR STOP "Mesh reading error"
      CALL checkBCIntegrity(sem % mesh, success)
      IF(.NOT. success)   ERROR STOP "Boundary condition specification error"
      CALL UserDefinedFinalSetup(sem, controlVariables)
!
!     ----------------------
!     Set the initial values
!     ----------------------
!
      IF ( controlVariables % logicalValueForKey(restartKey) )     THEN
         restartUnit = UnusedUnit()
         OPEN( UNIT = restartUnit, &
               FILE = controlVariables % stringValueForKey(restartFileNameKey,requestedLength = LINE_LENGTH), &
               FORM = "UNFORMATTED" )
               CALL LoadSolutionForRestart( sem, restartUnit )
         CLOSE( restartUnit )
      ELSE
         CALL UserDefinedInitialCondition(sem)
      END IF
!
!     -----------------------------
!     Construct the time integrator
!     -----------------------------
!
      cfl = controlVariables % doublePrecisionValueForKey("cfl")
      dt = MaxTimeStep( sem, cfl )

      CALL timeIntegrator % constructAsSteadyStateIntegrator &
                            (dt            = dt,  &
                             cfl           = cfl, &
                             numberOfSteps = controlVariables % integerValueForKey &
                             (numberOfTimeStepsKey), &
                             plotInterval  = controlVariables % integerValueForKey(outputIntervalKey))
      CALL timeIntegrator % setIterationTolerance(controlVariables % doublePrecisionValueForKey(convergenceToleranceKey))
!
!     --------------------
!     Prepare for plotting
!     --------------------
!
      IF ( controlVariables % stringValueForKey(plotFileNameKey, &
           requestedLength = LINE_LENGTH) /= "none" )     THEN
         plotUnit = UnusedUnit()
         ALLOCATE(plotter)
         ALLOCATE(plDataSource)
         
         CALL plotter % Construct(fUnit      = plotUnit,          &
                                  spA        = sem % spA,         &
                                  dataSource = plDataSource,      &
                                  newN       = controlVariables % integerValueForKey(numberOfPlotPointsKey))
         CALL timeIntegrator % setPlotter(plotter)
      END IF 
!
!     -----------------
!     Integrate in time
!     -----------------
!
      CALL stopWatch % start()
         CALL timeIntegrator % integrate(sem)
      CALL stopWatch % stop()
      
      PRINT *
      PRINT *, "Elapsed Time: ", stopWatch % elapsedTime(units = TC_SECONDS)
      PRINT *, "Total Time:   ", stopWatch % totalTime  (units = TC_SECONDS)
!
!     -----------------------------------------------------
!     Let the user perform actions on the computed solution
!     -----------------------------------------------------
!
      CALL UserDefinedFinalize(sem, timeIntegrator % time)
!
!     ------------------------------------
!     Save the results to the restart file
!     ------------------------------------
!
      IF(controlVariables % stringValueForKey(restartFileNameKey,LINE_LENGTH) /= "none")     THEN 
         restartUnit = UnusedUnit()
         OPEN( UNIT = restartUnit, &
               FILE = controlVariables % stringValueForKey(restartFileNameKey,LINE_LENGTH), &
               FORM = "UNFORMATTED" )
               CALL SaveSolutionForRestart( sem, restartUnit )
         CLOSE( restartUnit )
      END IF
!
!     ----------------
!     Plot the results
!     ----------------
!
      IF ( ASSOCIATED(plotter) )     THEN
         plotUnit = UnusedUnit()
         OPEN(UNIT = plotUnit, FILE = controlVariables % stringValueForKey(plotFileNameKey, &
                                                                requestedLength = LINE_LENGTH))
            CALL plotter % ExportToTecplot( elements = sem % mesh % elements )
         CLOSE(plotUnit)
      END IF 
!
!     --------
!     Clean up
!     --------
!
      IF(ASSOCIATED(plotter)) THEN
         CALL plotter % Destruct()
         DEALLOCATE(plotter)
         DEALLOCATE(plDataSource)
      END IF 
      CALL timeIntegrator % destruct()
      CALL sem % destruct()
      CALL destructSharedBCModule
      
      CALL UserDefinedTermination
      
      END PROGRAM NSLite3DMain
!
!//////////////////////////////////////////////////////////////////////// 
! 
      SUBROUTINE CheckBCIntegrity(mesh, success)
!
         USE HexMeshClass
         USE SharedBCModule
         USE BoundaryConditionFunctions, ONLY:implementedBCNames
         IMPLICIT NONE
!
!        ---------
!        Arguments
!        ---------
!
         TYPE(HexMesh) :: mesh
         LOGICAL       :: success
!
!        ---------------
!        Local variables
!        ---------------
!
         INTEGER                              :: i, j
         INTEGER                              :: faceID, eId
         CHARACTER(LEN=BC_STRING_LENGTH)      :: bcName, namedBC
         CHARACTER(LEN=BC_STRING_LENGTH)      :: bcType
         CLASS(FTMutableObjectArray), POINTER :: bcObjects
         CLASS(FTValue)             , POINTER :: v
         CLASS(FTObject), POINTER             :: obj
         
         success = .TRUE.
!
!        ----------------------------------------------------------
!        Check to make sure that the boundaries defined in the mesh
!        have an associated name in the control file.
!        ----------------------------------------------------------
         
         DO eID = 1, SIZE( mesh % elements )
            DO faceID = 1, 6
               namedBC = mesh % elements(eId) % boundaryName(faceID)
               IF( namedBC == emptyBCName ) CYCLE
               
               bcName = bcTypeDictionary % stringValueForKey(key             = namedBC,         &
                                                             requestedLength = BC_STRING_LENGTH)
               IF ( LEN_TRIM(bcName) == 0 )     THEN
                  PRINT *, "Control file does not define a boundary condition for boundary name = ", &
                            mesh % elements(eId) % boundaryName(faceID)
                  success = .FALSE.
                  return 
               END IF 
            END DO   
         END DO
!
!        --------------------------------------------------------------------------
!        Check that the boundary conditions to be applied are implemented
!        in the code. Keep those updated in the boundary condition functions module
!        --------------------------------------------------------------------------
!
         bcObjects => bcTypeDictionary % allObjects()
         DO j = 1, bcObjects % COUNT()
            obj => bcObjects % objectAtIndex(j)
            CALL castToValue(obj,v)
            bcType = v % stringValue(requestedLength = BC_STRING_LENGTH)
            DO i = 1, SIZE(implementedBCNames)
               IF ( bcType == implementedBCNames(i) )     THEN
                  success = .TRUE. 
                  EXIT 
               ELSE 
                  success = .FALSE. 
               END IF 
            END DO
            
            IF ( .NOT. success )     THEN
               PRINT *, "Boundary condition ", TRIM(bcType)," not implemented in this code"
               CALL bcObjects % release()
               IF(bcObjects % isUnreferenced()) DEALLOCATE (bcObjects)
               return
            END IF  
            
         END DO
         
         CALL bcObjects % release()
         IF(bcObjects % isUnreferenced()) DEALLOCATE (bcObjects)
         
      END SUBROUTINE checkBCIntegrity
!
!//////////////////////////////////////////////////////////////////////// 
! 
      SUBROUTINE CheckInputIntegrity( controlVariables, success )  
         USE FTValueDictionaryClass
         USE mainKeywordsModule
         IMPLICIT NONE
!
!        ---------
!        Arguments
!        ---------
!
         TYPE(FTValueDictionary) :: controlVariables
         LOGICAL                 :: success
!
!        ---------------
!        Local variables
!        ---------------
!
         CLASS(FTObject), POINTER :: obj
         INTEGER                  :: i
         success = .TRUE.
         
         DO i = 1, SIZE(mainKeywords)
            obj => controlVariables % objectForKey(mainKeywords(i))
            IF ( .NOT. ASSOCIATED(obj) )     THEN
               PRINT *, "Input file is missing entry for keyword: ",mainKeywords(i)
               success = .FALSE. 
            END IF  
         END DO  
         
         
      END SUBROUTINE checkInputIntegrity
