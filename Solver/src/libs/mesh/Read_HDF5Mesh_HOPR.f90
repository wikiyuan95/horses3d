!
!//////////////////////////////////////////////////////
!
!   @File:    ReadHDF5Mesh.f90
!   @Author:  Andrés Rueda (a.rueda@upm.es)
!   @Created: Tue Nov 01 14:00:00 2017
!   @Last revision date: Tue Nov 28 17:01:48 2017
!   @Last revision author: Juan (juan.manzanero@upm.es)
!   @Last revision commit: 86a8c105a49aa182fa3416a869f7efbbc764622a
!
!  Module or reading HDF5 meshes as written by HOPR
!  -> Only for hexahedral conforming meshes
!
!//////////////////////////////////////////////////////
!
module Read_HDF5Mesh_HOPR
   use HexMeshClass
   use SMConstants
   USE TransfiniteMapClass
   use FacePatchClass
   use MPI_Process_Info
#ifdef HAS_HDF5
   use HDF5
#endif
   implicit none
   
   private
   public ConstructMesh_FromHDF5File_, NumOfElems_HDF5
#ifdef HAS_HDF5
   integer(HID_T) :: file_id       ! File identifier
#endif
   integer        :: iError        ! Error flag
   
   ! Parameters defined in HOPR io
   INTEGER,PARAMETER              :: ELEM_FirstSideInd=3
   INTEGER,PARAMETER              :: ELEM_LastSideInd=4
   INTEGER,PARAMETER              :: ELEM_FirstNodeInd=5
   INTEGER,PARAMETER              :: ELEM_LastNodeInd=6
   
contains

   function NumOfElems_HDF5( fileName ) result(nelem)
      !----------------------------------
      CHARACTER(LEN=*), intent(in) :: fileName
      integer                      :: nelem
      !----------------------------------
#ifdef HAS_HDF5

      ! Initialize FORTRAN predefined datatypes
      call h5open_f(iError)
      
      ! Open the specified mesh file.
      call h5fopen_f (trim(filename), H5F_ACC_RDONLY_F, file_id, iError) ! instead of H5F_ACC_RDONLY_F one can also use  H5F_ACC_RDWR_F
      
      ! Read the number of elements

      CALL GetHDF5Attribute(File_ID,'nElems',1,IntegerScalar=nelem)
#else
      STOP ':: HDF5 is not linked correctly'
#endif
      
   end function NumOfElems_HDF5
!
!///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
!
!  -----------------------------------------------------------------------------------------------------------------------
!  Routine for reading a mesh in hdf5 format written by HOPR
!  Important:
!  -> The meshes must NOT be constructed using HOPR periodic boundaries! HORSES3D has its own way of imposing periodic BCs.
!  -> The nodes in the hdf5 file generated by HOPR refer to the high-order equidistant position
!     of the bases, i.e., every hexahedron has (bFaceOrder+1)^3 nodes.
!  -> There are 3 groups of local variables:
!     * Variables as called by Kopriva: As called in SUBROUTINE ConstructMesh_FromFile_ 
!        NOTE: If the same variable is called differently by Kopriva and HOPR, Kopriva's name is used. 
!     * Variables as called in HOPR
!     * Auxiliar variables
!  -----------------------------------------------------------------------------------------------------------------------
   subroutine ConstructMesh_FromHDF5File_( self, fileName, nodes, spA, Nx, Ny, Nz, MeshInnerCurves, success )
      implicit none
      !---------------------------------------------------------------
      class(HexMesh)     :: self
      CHARACTER(LEN=*)   :: fileName
      integer            :: nodes
      TYPE(NodalStorage) :: spA(0:)  
      INTEGER            :: Nx(:), Ny(:), Nz(:)     !<  Polynomial orders for all the elements
      logical            :: MeshInnerCurves
      LOGICAL            :: success
      !---------------------------------------------------------------
#ifdef HAS_HDF5
      ! Variables as called by Kopriva
      integer  :: numberOfElements  ! ...
      integer  :: bFaceOrder        ! Polynomial order for aproximating curved faces
      integer  :: numberOfNodes     ! Number of corner nodes in the geometry
      integer  :: numBFacePoints    ! Number of points for describing a curved mesh
      integer  :: numberOfBoundaryFaces
      INTEGER  :: numberOfFaces
      INTEGER                          :: nodeIDs(NODES_PER_ELEMENT), nodeMap(NODES_PER_FACE)
      CHARACTER(LEN=BC_STRING_LENGTH)  :: names(FACES_PER_ELEMENT)
      TYPE(FacePatch), DIMENSION(6)    :: facePatches
      REAL(KIND=RP)                    :: corners(NDIM,NODES_PER_ELEMENT) ! Corners of element
      type(SurfInfo_t), allocatable                :: SurfInfo(:)
      real(kind=RP), dimension(:)    , allocatable :: uNodes, vNodes
      real(kind=RP), dimension(:,:,:), allocatable :: values
      
      REAL(KIND=RP)  , DIMENSION(2)     :: uNodesFlat = [-1.0_RP,1.0_RP]
      REAL(KIND=RP)  , DIMENSION(2)     :: vNodesFlat = [-1.0_RP,1.0_RP]
      REAL(KIND=RP)  , DIMENSION(3,2,2) :: valuesFlat
      
      ! Variables as called in HOPR: For a description, see HOPR documentation
      integer                          :: nUniqueNodes
      integer                          :: nUniqueSides, nSides, nNodes
      integer         , allocatable    :: GlobalNodeIDs(:)
      double precision, allocatable    :: TempArray(:,:) !(kind=RP)
      real(kind=RP)   , allocatable    :: NodeCoords(:,:)
      integer         , allocatable    :: ElemInfo(:,:)
      integer         , allocatable    :: SideInfo(:,:)
      integer                          :: offset
      integer                          :: first, last
      INTEGER(HSIZE_T),POINTER         :: HSize(:)
      integer                          :: nBCs
      integer                          :: nDims
      CHARACTER(LEN=255), ALLOCATABLE  :: BCNames(:)
      
      
      ! Auxiliar variables
      integer :: i,j,k,l  ! Counters
      integer                    :: HOPRNodeID           ! Node ID in HOPR
      integer                    :: HCornerMap(8)        ! Map from the corner node index of an element to the local high-order node index used in HOPR
      integer                    :: HSideMap(6)          ! Map from the side index of an element in HORSES3D to the side index used in HOPR
      integer, allocatable       :: HNodeSideMap(:,:,:)  ! Map from the face-node-index of an element to the global node index of HOPR (for surface curvature)
      integer, allocatable       :: HOPRNodeMap(:)       ! Map from the global node index of HORSES3D to the global node index of HOPR
      real(kind=RP), allocatable :: TempNodes(:,:)       ! Nodes read from file to be exported to self % nodes
      logical                    :: CurveCondition
      
      TYPE(FacePatch), DIMENSION(6)    :: facePatchesHOPR
      !---------------------------------------------------------------
       
!
!     Initializations
!     ------------------------------------
      success               = .TRUE. !change?
      self % nodeType = nodes
      
!
!     Prepare to read file
!     ------------------------------------
      
      ! Initialize FORTRAN predefined datatypes
      call h5open_f(iError)
      
      ! Open the specified mesh file.
      call h5fopen_f (trim(filename), H5F_ACC_RDONLY_F, file_id, iError) ! instead of H5F_ACC_RDONLY_F one can also use  H5F_ACC_RDWR_F
        
!
!     Read important mesh attributes
!     ------------------------------
      CALL GetHDF5Attribute(File_ID,'nElems',1,IntegerScalar=numberOfElements)
      CALL GetHDF5Attribute(File_ID,'Ngeo',1,IntegerScalar=bFaceOrder)
      CALL GetHDF5Attribute(File_ID,'nSides',1,IntegerScalar=nSides)
      CALL GetHDF5Attribute(File_ID,'nUniqueSides',1,IntegerScalar=nUniqueSides)
      CALL GetHDF5Attribute(File_ID,'nNodes',1,IntegerScalar=nNodes)
      CALL GetHDF5Attribute(File_ID,'nUniqueNodes',1,IntegerScalar=nUniqueNodes)
      
      allocate(ElemInfo(6,1:numberOfElements))
      call ReadArrayFromHDF5(File_ID,'ElemInfo',2,(/6,numberOfElements/),0,IntegerArray=ElemInfo)
      
      offset=ElemInfo(ELEM_FirstNodeInd,1) ! hdf5 array starts at 0-> -1
      first=offset+1
      last =offset+nNodes
      
      ALLOCATE(GlobalNodeIDs(first:last),NodeCoords(1:3,first:last),TempArray(1:3,first:last))
      CALL ReadArrayFromHDF5(File_ID,'GlobalNodeIDs',1,(/nNodes/),offset,IntegerArray=GlobalNodeIDs)
      
      CALL ReadArrayFromHDF5(File_ID,'NodeCoords',2,(/3,nNodes/),offset,RealArray=TempArray)
      NodeCoords = REAL(TempArray,RP)
      
      offset=ElemInfo(ELEM_FirstSideInd,1) ! hdf5 array starts at 0-> -1  
      first=offset+1
      last =offset+nSides
      ALLOCATE(SideInfo(5,first:last))
      CALL ReadArrayFromHDF5(File_ID,'SideInfo',2,(/5,nSides/),offset,IntegerArray=SideInfo) ! There's a mistake in the documentation of HOPR regarding the SideInfo size!!
      
      ! Read boundary names from HDF5 file
      CALL GetHDF5DataSize(File_ID,'BCNames',nDims,HSize)
      nBCs=INT(HSize(1),4)
      DEALLOCATE(HSize)
      ALLOCATE(BCNames(nBCs)) !, BCMapping(nBCs))
      CALL ReadArrayFromHDF5(File_ID,'BCNames',1,(/nBCs/),Offset,StrArray=BCNames)  ! Type is a dummy type only
      
!      
!     Set up for face patches
!     Face patches are defined at equidistant points in HOPR (not Chebyshev-Lobatto as in .mesh format)
!     ---------------------------------------
      WRITE(STD_OUT,*) 'Face order=',bFaceOrder
      
      numBFacePoints = bFaceOrder + 1
      allocate(uNodes(numBFacePoints))
      allocate(vNodes(numBFacePoints))
      allocate(values(3,numBFacePoints,numBFacePoints))
      
      do i = 1, numBFacePoints
         uNodes(i) = -1._RP + (i-1) * (2._RP/bFaceOrder)
         vNodes(i) = uNodes(i)
      end do      
      
      DO k = 1, 6 ! All the patches read from the hdf5 file will have order bFaceOrder
         CALL facePatchesHOPR(k) % construct(uNodes, vNodes) 
      END DO  
      
!      
!     Some other initializations
!     ---------------------------------------
      self % no_of_elements = numberOfElements
      numberOfBoundaryFaces = 0
      corners               = 0.0_RP
      
      HSideMap = HOPR2HORSESSideMap()
      HCornerMap = HOPR2HORSESCornerMap(bFaceOrder)
      call HOPR2HORSESNodeSideMap(bFaceOrder,HNodeSideMap)
      
      ALLOCATE( self % elements(numberOfelements) )
      allocate( SurfInfo(numberOfelements) )
      
      call InitNodeMap (TempNodes , HOPRNodeMap, nUniqueNodes)
      
!      
!     Now we construct the elements
!     ---------------------------------------

      do l = 1, numberOfElements
         
         ! Read nodeIDs and add them to the self%nodes array
         DO k = 1, NODES_PER_ELEMENT
            HOPRNodeID = ElemInfo(ELEM_FirstNodeInd,l) + HCornerMap(k)
            
            corners(:,k) = NodeCoords(:,HOPRNodeID)
            
            call AddToNodeMap (TempNodes , HOPRNodeMap, corners(:,k), GlobalNodeIDs(HOPRNodeID), nodeIDs(k))
         END DO
         
         do k = 1, FACES_PER_ELEMENT
            j = SideInfo(5,ElemInfo(3,l) + HSideMap(k))
            if (j == 0) then
               names(k) = emptyBCName
            else
               names(k) = trim(BCNames(j))
            end if
         end do
         
         if (MeshInnerCurves) then
            CurveCondition = (bFaceOrder == 1)
         else
            CurveCondition = all(names == emptyBCName)
         end if
         
         if (CurveCondition) then
!
!           HOPR does not specify the order of curvature of individual faces. Therefore, we 
!           will suppose that self is a straight-sided hex when bFaceOrder == 1, and
!           for inner elements when MeshInnerCurves == .false. (control file variable 'mesh inner curves'). 
!           In these cases, set the corners of the hex8Map and use that in determining the element geometry.
!           -----------------------------------------------------------------------------
            SurfInfo(l) % IsHex8 = .TRUE.
            SurfInfo(l) % corners = corners
            
         else
!
!           Otherwise, we have to look at each of the faces of the element 
!           --------------------------------------------------------------
            
            DO k = 1, FACES_PER_ELEMENT 
               IF ( names(k) == emptyBCName .and. (.not. MeshInnerCurves) )     THEN   ! This doesn't work when the boundary surface of the element is not only curved in the normal direction, but also in some tangent direction. 
!
!                 ----------
!                 Flat faces
!                 ----------
!
                  nodeMap           = localFaceNode(:,k)
                  valuesFlat(:,1,1) = corners(:,nodeMap(1))
                  valuesFlat(:,2,1) = corners(:,nodeMap(2))
                  valuesFlat(:,2,2) = corners(:,nodeMap(3))
                  valuesFlat(:,1,2) = corners(:,nodeMap(4))
                  
                  call SurfInfo(l) % facePatches(k) % construct(uNodesFlat, vNodesFlat, valuesFlat)
                  
               ELSE
!
!                 -------------
!                 Curved faces 
!                 -------------
!
                  DO j = 1, numBFacePoints
                     DO i = 1, numBFacePoints
                        HOPRNodeID = ElemInfo(ELEM_FirstNodeInd,l) + HNodeSideMap(i,j,k)
                        values(:,i,j) = NodeCoords(:,HOPRNodeID)
                     END DO  
                  END DO
                  
                  call SurfInfo(l) % facePatches(k) % construct(uNodes, vNodes, values)

               END IF
               
            END DO
            
         end if
         
!
!        Now construct the element
!        -------------------------
!
         call self % elements(l) % Construct (spA(Nx(l)), spA(Ny(l)), spA(Nz(l)), nodeIDs , l, l) ! TODO: Change for MPI
         
         CALL SetElementBoundaryNames( self % elements(l), names )
            
         DO k = 1, 6
            IF(TRIM(names(k)) /= emptyBCName) then
               numberOfBoundaryFaces = numberOfBoundaryFaces + 1
               if ( all(trim(names(k)) .ne. zoneNameDictionary % allKeys()) ) then
                  call zoneNameDictionary % addValueForKey(trim(names(k)), trim(names(k)))
               end if
            end if
         END DO  
         
      end do      ! l = 1, numberOfElements
      
      call FinishNodeMap (TempNodes , HOPRNodeMap, self % nodes)
      
      numberOfNodes = size(self % nodes)
      
!     Construct the element faces
!     ---------------------------
!
      numberOfFaces        = (6*numberOfElements + numberOfBoundaryFaces)/2
      self % numberOfFaces = numberOfFaces
      
      ALLOCATE( self % faces(self % numberOfFaces) )
      CALL ConstructFaces( self, success )
!
!
!     -------------------------
!     Build the different zones
!     -------------------------
!
      call self % ConstructZones()
!
!     ---------------------------
!     Construct periodic faces
!     ---------------------------
!
      CALL ConstructPeriodicFaces( self )
!
!     ---------------------------
!     Delete periodic- faces
!     ---------------------------
!
      CALL DeletePeriodicMinusFaces( self )
!
!     ---------------------------
!     Assign faces ID to elements
!     ---------------------------
!
      CALL getElementsFaceIDs(self)
!        --------------------- 
!        Define boundary faces 
!        --------------------- 
! 
      call self % DefineAsBoundaryFaces() 
! 
!
!     ------------------------------
!     Set the element connectivities
!     ------------------------------
      call self % SetConnectivitiesAndLinkFaces(spA,nodes)
!
!     ---------------------------------------
!     Construct elements' and faces' geometry
!     ---------------------------------------
!
      call self % ConstructGeometry(spA,SurfInfo)
!
!     Finish up
!     ---------
!      
      CALL self % Describe( trim(fileName) )
      self % Ns = Nx
!
!     -------------------------------------------------------------
!     Prepare mesh for I/O only if the code is running sequentially
!     -------------------------------------------------------------
!
      if ( .not. MPI_Process % doMPIAction ) then
         call self % PrepareForIO
         call self % Export( trim(fileName) )
      end if

#else
      STOP ':: HDF5 is not linked correctly'
#endif
   end subroutine ConstructMesh_FromHDF5File_
   
#ifdef HAS_HDF5
!
!///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
!
!  -----------------------------------------------------------------------------------------------------------------------
   ! Copied from HOPR
   ! Copyright (C) 2015  Prof. Claus-Dieter Munz <munz@iag.uni-stuttgart.de>
   ! This file is part of HOPR, a software for the generation of high-order meshes.
   !
   ! HOPR is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License 
   ! as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.
!  -----------------------------------------------------------------------------------------------------------------------
   SUBROUTINE GetHDF5Attribute(Loc_ID_in,AttribName,nVal,DatasetName,RealScalar,IntegerScalar,StrScalar,LogicalScalar,&
                                                                  RealArray,IntegerArray)
   !===================================================================================================================================
   ! Subroutine to read attributes from HDF5 file.
   !===================================================================================================================================
   ! MODULES
   ! IMPLICIT VARIABLE HANDLING
      IMPLICIT NONE
      !-----------------------------------------------------------------------------------------------------------------------------------
      ! INPUT VARIABLES
      INTEGER(HID_T), INTENT(IN)           :: Loc_ID_in  ! ?
      INTEGER,INTENT(IN)                              :: nVal  ! ?
      CHARACTER(LEN=*), INTENT(IN)         :: AttribName  ! ?
      CHARACTER(LEN=*),OPTIONAL,INTENT(IN) :: DatasetName  ! ?
      !-----------------------------------------------------------------------------------------------------------------------------------
      ! OUTPUT VARIABLES
      REAL              ,OPTIONAL,INTENT(OUT) :: RealArray(nVal)  ! ?
      INTEGER           ,OPTIONAL,INTENT(OUT) :: IntegerArray(nVal)  ! ?
      REAL              ,OPTIONAL,INTENT(OUT) :: RealScalar  ! ?
      INTEGER           ,OPTIONAL,INTENT(OUT) :: IntegerScalar  ! ?
      LOGICAL           ,OPTIONAL,INTENT(OUT) :: LogicalScalar  ! ?
      CHARACTER(LEN=255),OPTIONAL,INTENT(OUT) :: StrScalar  ! ?
      !-----------------------------------------------------------------------------------------------------------------------------------
      ! LOCAL VARIABLES
      INTEGER(HID_T)                 :: Attr_ID, Type_ID,Loc_ID  ! ?
      INTEGER(HSIZE_T), DIMENSION(1) :: Dimsf  ! ?
      INTEGER                        :: inttolog  ! ?
      !===================================================================================================================================

      Dimsf(1)=nVal
      IF(PRESENT(DatasetName))THEN
       ! Open dataset
        CALL H5DOPEN_F(File_ID, TRIM(DatasetName),Loc_ID, iError)
      ELSE
        Loc_ID=Loc_ID_in
      END IF
      ! Create scalar data space for the attribute.
      ! Create the attribute for group Loc_ID.
      CALL H5AOPEN_F(Loc_ID, TRIM(AttribName), Attr_ID, iError)
      ! Write the attribute data.
      IF(PRESENT(RealArray))THEN
        CALL H5AREAD_F(Attr_ID, H5T_NATIVE_DOUBLE, RealArray, Dimsf, iError)
      END IF
      IF(PRESENT(RealScalar))THEN
        CALL H5AREAD_F(Attr_ID, H5T_NATIVE_DOUBLE, RealScalar, Dimsf, iError)
      END IF
      IF(PRESENT(IntegerArray))THEN
        CALL H5AREAD_F(Attr_ID, H5T_NATIVE_INTEGER , IntegerArray, Dimsf, iError)
      END IF
      IF(PRESENT(IntegerScalar))THEN
        CALL H5AREAD_F(Attr_ID, H5T_NATIVE_INTEGER , IntegerScalar, Dimsf, iError)
      END IF
      IF(PRESENT(LogicalScalar))THEN
        CALL H5AREAD_F(Attr_ID, H5T_NATIVE_INTEGER , inttolog, Dimsf, iError)
        LogicalScalar=(inttolog.EQ.1)
      END IF
      IF(PRESENT(StrScalar))THEN
        CALL H5AGET_TYPE_F(Attr_ID, Type_ID, iError)  ! Get HDF5 data type for character string
        CALL H5AREAD_F(Attr_ID, Type_ID, StrScalar, Dimsf, iError)
        CALL H5TCLOSE_F(Type_ID, iError)
        
      END IF
      ! Close the attribute.
      CALL H5ACLOSE_F(Attr_ID, iError)
      IF(PRESENT(DataSetName))THEN
        ! Close the dataset and property list.
        CALL H5DCLOSE_F(Loc_ID, iError)
      END IF

   END SUBROUTINE GetHDF5Attribute
   
!
!///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
!
!  -----------------------------------------------------------------------------------------------------------------------
   ! Copied from HOPR.
   !  -> Corrected the fact that RealArray had to be defined as double precision!!
   ! Copyright (C) 2015  Prof. Claus-Dieter Munz <munz@iag.uni-stuttgart.de>
   ! This file is part of HOPR, a software for the generation of high-order meshes.
   !
   ! HOPR is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License 
   ! as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.
!  -----------------------------------------------------------------------------------------------------------------------
   SUBROUTINE ReadArrayFromHDF5(Loc_ID,ArrayName,Rank,nVal,Offset_in,RealArray,IntegerArray,StrArray)
   !===================================================================================================================================
   ! Subroutine to read arrays of rank "Rank" with dimensions "Dimsf(1:Rank)".
   !===================================================================================================================================
   ! MODULES
   ! IMPLICIT VARIABLE HANDLING
      IMPLICIT NONE
      !-----------------------------------------------------------------------------------------------------------------------------------
      ! INPUT VARIABLES
      INTEGER, INTENT(IN)                :: Rank ! ?
      INTEGER, INTENT(IN)                :: Offset_in  ! ?
      INTEGER, INTENT(IN)                            :: nVal(Rank)  ! ?
      INTEGER(HID_T), INTENT(IN)         :: Loc_ID  ! ?
      CHARACTER(LEN=*),INTENT(IN)        :: ArrayName  ! ?
      !-----------------------------------------------------------------------------------------------------------------------------------
      ! OUTPUT VARIABLES
      double precision              ,DIMENSION(Rank),OPTIONAL,INTENT(OUT) :: RealArray  ! ?
      INTEGER           ,DIMENSION(Rank),OPTIONAL,INTENT(OUT) :: IntegerArray  ! ?
      CHARACTER(LEN=255),DIMENSION(Rank),OPTIONAL,INTENT(OUT) :: StrArray  ! ?
      !-----------------------------------------------------------------------------------------------------------------------------------
      ! LOCAL VARIABLES
      INTEGER(HID_T)                 :: DSet_ID, Type_ID, MemSpace, FileSpace, PList_ID  ! ?
      INTEGER(HSIZE_T)               :: Offset(Rank),Dimsf(Rank)  ! ?
      !===================================================================================================================================
      ! Read array -----------------------------------------------------------------------------------------------------------------------
      Dimsf=nVal
      CALL H5SCREATE_SIMPLE_F(Rank, Dimsf, MemSpace, iError)
      CALL H5DOPEN_F(Loc_ID, TRIM(ArrayName) , DSet_ID, iError)
      ! Define and select the hyperslab to use for reading.
      CALL H5DGET_SPACE_F(DSet_ID, FileSpace, iError)
      Offset(:)=0
      Offset(1)=Offset_in
      CALL H5SSELECT_HYPERSLAB_F(FileSpace, H5S_SELECT_SET_F, Offset, Dimsf, iError)
      ! Create property list
      CALL H5PCREATE_F(H5P_DATASET_XFER_F, PList_ID, iError)
      ! Read the data
      IF(PRESENT(RealArray))THEN
        CALL H5DREAD_F(DSet_ID,H5T_NATIVE_DOUBLE,&
                        RealArray    ,Dimsf,iError,mem_space_id=MemSpace,file_space_id=FileSpace,xfer_prp=PList_ID)
      END IF
      IF(PRESENT(IntegerArray))THEN
        CALL H5DREAD_F(DSet_ID,H5T_NATIVE_INTEGER, &
                        IntegerArray ,Dimsf,iError,mem_space_id=MemSpace,file_space_id=FileSpace,xfer_prp=PList_ID)
      END IF
      IF(PRESENT(StrArray))THEN
        ! Get datatype for the character string array
        CALL H5DGET_TYPE_F(DSet_ID, Type_ID, iError)
        CALL H5DREAD_F(DSet_ID,Type_ID,&
                        StrArray     ,Dimsf,iError,mem_space_id=MemSpace,file_space_id=FileSpace,xfer_prp=PList_ID)
        CALL H5TCLOSE_F(Type_ID, iError)
      END IF

      ! Close the property list
      CALL H5PCLOSE_F(PList_ID,iError)
      ! Close the file dataspace
      CALL H5SCLOSE_F(FileSpace,iError)
      ! Close the dataset
      CALL H5DCLOSE_F(DSet_ID, iError)
      ! Close the memory dataspace
      CALL H5SCLOSE_F(MemSpace,iError)
   
   END SUBROUTINE ReadArrayFromHDF5
!
!///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
!
!  -----------------------------------------------------------------------------------------------------------------------
   ! Copied from HOPR.
   ! Copyright (C) 2015  Prof. Claus-Dieter Munz <munz@iag.uni-stuttgart.de>
   ! This file is part of HOPR, a software for the generation of high-order meshes.
   !
   ! HOPR is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License 
   ! as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.
!  -----------------------------------------------------------------------------------------------------------------------
   SUBROUTINE GetHDF5DataSize(Loc_ID,DSetName,nDims,Size)
   !===================================================================================================================================
   ! Subroutine to get the size of an array stored in the hdf5 file
   !===================================================================================================================================
   ! MODULES
   ! IMPLICIT VARIABLE HANDLING
      IMPLICIT NONE
      !-----------------------------------------------------------------------------------------------------------------------------------
      ! INPUT VARIABLES
      CHARACTER(LEN=*),INTENT(IN)               :: DSetName  ! ?
      INTEGER(HID_T),INTENT(IN)      :: Loc_ID  ! ?
      !-----------------------------------------------------------------------------------------------------------------------------------
      ! OUTPUT VARIABLES
      INTEGER,INTENT(OUT)            :: nDims  ! ?
      INTEGER(HSIZE_T),POINTER,INTENT(OUT) :: Size(:)  ! ?
      !-----------------------------------------------------------------------------------------------------------------------------------
      ! LOCAL VARIABLES
      INTEGER(HID_T)                 :: DSet_ID,FileSpace  ! ?
      INTEGER(HSIZE_T), POINTER      :: SizeMax(:)  ! ?
      !===================================================================================================================================
      !WRITE(UNIT_stdOut,'(A,A,A)')'GET SIZE OF "',TRIM(DSetName),'" IN HDF5 FILE... '
      ! Initialize FORTRAN predefined datatypes

      ! Get size of array ----------------------------------------------------------------------------------------------------------------
      ! Open the dataset with default properties.
      CALL H5DOPEN_F(Loc_ID, TRIM(DSetName) , DSet_ID, iError)
      ! Get the data space of the dataset.
      CALL H5DGET_SPACE_F(DSet_ID, FileSpace, iError)
      ! Get number of dimensions of data space
      CALL H5SGET_SIMPLE_EXTENT_NDIMS_F(FileSpace, nDims, iError)
      ! Get size and max size of data space
      ALLOCATE(Size(nDims),SizeMax(nDims))
      CALL H5SGET_SIMPLE_EXTENT_DIMS_F(FileSpace, Size, SizeMax, iError)
      CALL H5SCLOSE_F(FileSpace, iError)
      CALL H5DCLOSE_F(DSet_ID, iError)

      !WRITE(UNIT_stdOut,*)'...DONE!'
      !WRITE(UNIT_stdOut,'(132("-"))')

   END SUBROUTINE GetHDF5DataSize

!
!///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
!
!  -----------------------------------------------------------------------------------------------------------------------
!  Mapping between corner nodes needed in HORSES3D and the high-order nodes used by HOPR 
!  The mapping is the same as the one for the CNGS standard.
!  -----------------------------------------------------------------------------------------------------------------------
   pure function HOPR2HORSESCornerMap(N) result(CGNSCornerMap)
      implicit none
      !-----------------------------
      integer, intent(in)   :: N !<  Order of boundaries
      integer, dimension(8) :: CGNSCornerMap
      !-----------------------------
      CGNSCornerMap(1) =  1
      CGNSCornerMap(2) = (N+1)
      CGNSCornerMap(3) = (N+1)**2
      CGNSCornerMap(4) =  N*(N+1)+1
      CGNSCornerMap(5) =  N*(N+1)**2+1
      CGNSCornerMap(6) =  N*(N+1)**2+(N+1)
      CGNSCornerMap(7) = (N+1)**3
      CGNSCornerMap(8) =  N*(N+1)*(N+2)+1
      
   end function HOPR2HORSESCornerMap
!
!///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
!
!  -----------------------------------------------------------------------------------------------------------------------
!  Mapping between the side index used by HORSES 3D and the ones used by HOPR 
!  The mapping is the same as the one for the CNGS standard.
!  -----------------------------------------------------------------------------------------------------------------------
   pure function HOPR2HORSESSideMap() result(HSideMap)
      implicit none
      integer :: HSideMap(6)
      
      HSideMap(1) = 2
      HSideMap(2) = 4
      HSideMap(3) = 1
      HSideMap(4) = 3
      HSideMap(5) = 6
      HSideMap(6) = 5
   end function HOPR2HORSESSideMap
!
!///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
!
!  -----------------------------------------------------------------------------------------------------------------------
!  Mapping between the high-order nodes used by HOPR and the nodes on the surfaces needed in HORSES3D
!  The mapping is DIFFERENT than the one in the CNGS standard.
!  SideMap returns the local HOPR index of an i,j position on the face of the element
!  -----------------------------------------------------------------------------------------------------------------------
   subroutine HOPR2HORSESNodeSideMap(N,HSideMap)
      implicit none
      !------------------------------------
      integer, intent(in)                 :: N
      integer, allocatable, intent(inout) :: HSideMap(:,:,:)
      !------------------------------------
      integer :: i,j,k ! Coordinate counters
      integer :: FirstIdx
      !------------------------------------
      
      allocate (HSideMap(N+1,N+1,6))

      ! This is the same code as in src/libs/mesh/HexelementConnectivityDefinitions.f90
      ! But rotated in the same way as the cube in the HOPR documentation... for reference!!
      !----------------------------------------------------------------------+   ! Here the axis definitions for reference!!
      !                                                                      |
      !  ELEMENT GEOMETRY, 8 NODES                                           |
      !  ------------------------------------------------------              | INTEGER, DIMENSION(2,6) :: axisMap =     &
      !                                                                      |         RESHAPE( (/1, 3,                 & ! Face 1 (x,z)
      !                                                                      |                    1, 3,                 & ! Face 2 (x,z)
      !                                   8 --------------- 7                |                    1, 2,                 & ! Face 3 (x,y)
      !                               -                  -                   |                    2, 3,                 & ! Face 4 (y,z)
      !                            -     |           -     |                 |                    1, 2,                 & ! Face 5 (x,y)
      !                         -        |        -        |                 |                    2, 3/)                & ! Face 6 (y,z)
      !                     -       (5)  |     -           |                 |         ,(/2,6/))
      !                  -               |  -    (2)       |                 |
      !                -                 -                 |                 |
      !             5 --------------- 6                    |                 |
      !                                  |    (4)          |                 |
      !             |        (6)      |                                      |
      !             |                 |  4 --------------- 3                 |
      !             |                 |                 -     ZETA           |
      !             |       (1)    -  |              -           |  /ETA     |
      !             |           -     |  (3)      -              | /         |
      !             |        -        |        -                 |/     XI   |
      !             |     -           |     -                    -------     |
      !                -                 -                                   |
      !             1 --------------- 2                                      |
      !----------------------------------------------------------------------|
      
      ! Face 1
      !-------
      
      do j = 1, N + 1
         FirstIdx = (j-1)*(N+1)*(N+1) + 1 
         HSideMap(:,j,1) = (/ (k, k=FirstIdx,FirstIdx+N) /)   !j
      end do
      
      ! Face 2
      !-------
      
      do j = 1, N + 1
         FirstIdx = (N*(N+1)+1) + (j-1)*(N+1)*(N+1)
         HSideMap(:,j,2) = (/ (k, k=FirstIdx,FirstIdx+N) /)   !j
      end do
      
      ! Face 3 (the easy one!)
      !-----------------------
      k=0
      do j = 1, N + 1
         do i = 1, N + 1
            k = k+1
            HSideMap(i,j,3) = k
         end do
      end do
      
      ! Face 4
      !-------
      
      do j = 1, N + 1
         FirstIdx = (N+1) + (j-1)*(N+1)*(N+1)
         HSideMap(:,j,4) = (/ (k, k=FirstIdx,FirstIdx+(N+1)*N,N+1) /)
      end do
      
      ! Face 5 (the other easy one!)
      !-----------------------------
      k=N*(N+1)**2
      do j = 1, N + 1
         do i = 1, N + 1
            k = k+1
            HSideMap(i,j,5) = k
         end do
      end do
      
      ! Face 6
      !-------
      
      do j = 1, N + 1
         FirstIdx = (j-1)*(N+1)**2 + 1
         HSideMap(:,j,6) = (/ (k, k=FirstIdx,FirstIdx+(N+1)*N,N+1) /)
      end do
      
   end subroutine HOPR2HORSESNodeSideMap

!
!///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
!///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
!    
!    Following routines are for generating the self % nodes... 
!    
!///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

!
!///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
!
!  ----------------------------------------------------------------
!  Initialize: allocating to the nUniqueNodes.. 
!     In general, nCornerNodes <= nUniqueNodes
!  ----------------------------------------------------------------
   subroutine InitNodeMap (TempNodes , HOPRNodeMap, nUniqueNodes)
      implicit none
      !--------------------------------------------
      real(kind=RP), allocatable, intent(inout) :: TempNodes(:,:)
      integer      , allocatable, intent(inout) :: HOPRNodeMap(:)
      integer                   , intent(in)    :: nUniqueNodes
      !--------------------------------------------
      
      allocate (TempNodes(3,nUniqueNodes))
      allocate (HOPRNodeMap(nUniqueNodes))
      
      TempNodes   = 0._RP
      HOPRNodeMap = 0
      
   end subroutine InitNodeMap
   
!
!///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
!
!  ----------------------------------------------------------------
!  Add a new entry to the node map
!  ----------------------------------------------------------------
   subroutine AddToNodeMap (TempNodes , HOPRNodeMap, newnode, HOPRGlobalID,nodeID)
      implicit none
      !--------------------------------------------
      real(kind=RP), intent(inout) :: TempNodes(:,:)
      integer      , intent(inout) :: HOPRNodeMap(:)
      real(kind=RP), intent(in)    :: newnode(3)
      integer      , intent(in)    :: HOPRGlobalID
      integer      , intent(out)   :: nodeID          ! Node ID in HORSES3D!
      !--------------------------------------------
      integer, save :: idx = 0   ! Index of new element to add
      integer       :: i         ! Counter
      !--------------------------------------------
      
      do i = 1, idx
         if (HOPRGlobalID == HOPRNodeMap(i)) then
            nodeID = i
            return
         end if
      end do
      
      idx = idx + 1
      nodeID = idx
      
      TempNodes(:,idx) = newnode
      HOPRNodeMap(idx) = HOPRGlobalID
      
   end subroutine AddToNodeMap

!
!///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
!
!  ----------------------------------------------------------------
!  Construct nodes of mesh and deallocate temporal arrays
!  ----------------------------------------------------------------
   subroutine FinishNodeMap (TempNodes , HOPRNodeMap, nodes)
      implicit none
      !--------------------------------------------
      real(kind=RP), allocatable, intent(inout) :: TempNodes(:,:)
      integer      , allocatable, intent(inout) :: HOPRNodeMap(:)
      type(Node)   , allocatable, intent(inout) :: nodes(:)
      !--------------------------------------------
      integer       :: i,j       ! Counters
      integer       :: nUniqueNodes
      !--------------------------------------------
      
      nUniqueNodes = size(HOPRNodeMap)
      
      do i = 1, nUniqueNodes
         if (HOPRNodeMap(i) == 0) exit
      end do
      
      if (i > nUniqueNodes) i = nUniqueNodes
      
      allocate (nodes(i))
      
      DO j = 1, i 
         CALL ConstructNode( nodes(j), TempNodes(:,j), j ) ! TODO: Change for MPI
      END DO
      
      deallocate (TempNodes)
      deallocate (HOPRNodeMap)
      
   end subroutine FinishNodeMap
#endif
end module Read_HDF5Mesh_HOPR
