!
!////////////////////////////////////////////////////////////////////////
!
!      HexmeshTestsMain.f90
!      Created: May 27, 2015 at 11:01 AM 
!      By: David Kopriva  
!
!////////////////////////////////////////////////////////////////////////
!
      PROGRAM HexMeshTestsMain 
         use SMConstants
         USE TestSuiteManagerClass
         use MPI_Process_Info
         use PhysicsStorage, only: SetReferenceLength
         IMPLICIT NONE  
         TYPE(TestSuiteManager) :: testSuite
         INTEGER                :: numberOfFailures
         EXTERNAL               :: testTwoBoxesMeshConstruction
         EXTERNAL               :: testTwoElementCylindersMesh
         EXTERNAL               :: MeshFileTest

         call MPI_Process % Init
         
         CALL testSuite % init()

         call SetReferenceLength(1.0_RP)
         
         CALL testSuite % addTestSubroutineWithName(testSubroutine = testTwoBoxesMeshConstruction,&
                                                    testName = "Mesh Construction for Two Boxes")
         CALL testSuite % addTestSubroutineWithName(testSubroutine = testTwoElementCylindersMesh,&
                                                    testName = "Mesh Construction for Two Stacked cylinders")
         CALL testSuite % addTestSubroutineWithName(testSubroutine = MeshFileTest,&
                                                    testName = "Simple Box Generated by Spec Mesh")
         CALL testSuite % performTests(numberOfFailures)
         
         CALL testSuite % finalize()
         
         IF(numberOfFailures > 0)   STOP 99

         call MPI_Process % Close
         
      END PROGRAM HexMeshTestsMain