!
!////////////////////////////////////////////////////////////////////////
!
!      MeshFileTest.f90
!      Created: June 1, 2015 at 11:29 AM 
!      By: David Kopriva  
!
!////////////////////////////////////////////////////////////////////////
!
      SUBROUTINE MeshFileTest  
         IMPLICIT NONE
         
         CALL readMeshFilewithName("SimpleBox.mesh")         
!         CALL readMeshFilewithName("BoxAroundCircle3D.mesh")
      END SUBROUTINE MeshFileTest
!
!//////////////////////////////////////////////////////////////////////// 
! 
      SUBROUTINE readMeshFilewithName(meshfileName)
         USE FTAssertions
         USE HexMeshClass 
         USE NodalStorageClass
         use ElementClass
         use ReadMeshFile
         IMPLICIT NONE  
         
         TYPE(HexMesh)                      :: mesh
         INTEGER                            :: N(3)
         INTEGER, ALLOCATABLE               :: Nvector(:)
         INTEGER                            :: nelem
         INTEGER                            :: fUnit
         INTEGER                            :: id, l
         CHARACTER(LEN=*)                   :: meshFileName
         LOGICAL                            :: success
         
         N = 6
         
         OPEN(newunit = fUnit, FILE = meshFileName )  
            READ(fUnit,*) l, nelem, l                    ! Here l is used as default reader since this variables are not important now
         CLOSE(fUnit)
         
         ALLOCATE (Nvector(nelem))
         Nvector = N(1)             ! No anisotropy
         call InitializeNodalStorage(N(1))
         
         call NodalStorage(N(1)) % Construct(GAUSS, N(1))
         call NodalStorage(N(2)) % Construct(GAUSS, N(2))
         call NodalStorage(N(3)) % Construct(GAUSS, N(3))
         CALL constructMeshFromFile(mesh,meshfileName,GAUSS, Nvector,Nvector,Nvector, .TRUE., 0, success)
         CALL FTAssert(test = success,msg = "Mesh file read properly")
         IF(.NOT. success) RETURN 
         
         DO id = 1, SIZE(mesh % elements)
            CALL allocateElementStorage(self = mesh % elements(id),&
                                        Nx = N(1), Ny = N(2), Nz = N(3), computeGradients = .FALSE.) 
         END DO
         
      END SUBROUTINE readMeshFilewithName
